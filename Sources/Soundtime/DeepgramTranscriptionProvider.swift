import Foundation

final class DeepgramTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    enum TranscriptionError: LocalizedError {
        case missingAPIKey
        case missingInput
        case invalidResponse(String)
        case httpError(statusCode: Int, body: String)
        case unsupportedLongFormChunking(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Add a Deepgram API key in Preferences before using Deepgram transcription."
            case .missingInput:
                "There is no audio asset to send to Deepgram."
            case let .invalidResponse(message):
                "Deepgram returned an unexpected response: \(message)"
            case let .httpError(statusCode, body):
                Self.httpErrorDescription(statusCode: statusCode, body: body)
            case let .unsupportedLongFormChunking(message):
                message
            }
        }

        private static func httpErrorDescription(statusCode: Int, body: String) -> String {
            let bodySummary = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = bodySummary.isEmpty ? "" : " \(bodySummary)"
            switch statusCode {
            case 401, 403:
                return "Deepgram rejected the API key. Check Preferences or DEEPGRAM_API_KEY.\(suffix)"
            case 402:
                return "Deepgram says the account needs credits before this request can run.\(suffix)"
            case 413:
                return "Deepgram rejected this audio because the upload is too large. Try a shorter selection.\(suffix)"
            case 429:
                return "Deepgram rate-limited the request. Try again in a moment.\(suffix)"
            case 504:
                return "Deepgram timed out while transcribing this audio. Soundtime should retry or chunk longer files.\(suffix)"
            case 500..<600:
                return "Deepgram had a server-side issue while transcribing this audio.\(suffix)"
            default:
                return "Deepgram request failed (\(statusCode)).\(suffix)"
            }
        }
    }

    let identifier = "deepgram.nova-3"
    let displayName = "Deepgram Nova-3"

    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL
    private let modelName: String
    private let maximumSingleRequestDuration: TimeInterval
    private let chunkDuration: TimeInterval
    private let chunkContextOverlap: TimeInterval
    private let maximumConcurrentChunks: Int
    private let maximumRetryCount: Int
    private let activeTasks = DeepgramURLSessionTaskRegistry()
    private let recoveryStore: TranscriptionChunkRecoveryStore

    init?(
        apiKey: String? = AudioProcessingCredentials.deepgramAPIKey(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.deepgram.com")!,
        modelName: String = "nova-3",
        maximumSingleRequestDuration: TimeInterval = 8 * 60,
        chunkDuration: TimeInterval = 8 * 60,
        chunkContextOverlap: TimeInterval = 2,
        maximumConcurrentChunks: Int = 2,
        maximumRetryCount: Int = 2,
        recoveryStore: TranscriptionChunkRecoveryStore = TranscriptionChunkRecoveryStore()
    ) {
        guard let apiKey, !apiKey.isEmpty else {
            return nil
        }

        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
        self.modelName = modelName
        self.maximumSingleRequestDuration = maximumSingleRequestDuration
        self.chunkDuration = chunkDuration
        self.chunkContextOverlap = chunkContextOverlap
        self.maximumConcurrentChunks = max(maximumConcurrentChunks, 1)
        self.maximumRetryCount = max(maximumRetryCount, 0)
        self.recoveryStore = recoveryStore
    }

    func transcribe(
        _ request: TranscriptionRequest,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> TranscriptionResult {
        guard request.inputAsset.duration > 0 else {
            throw TranscriptionError.missingInput
        }

        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .preparing,
            fractionCompleted: 0.03,
            message: "Preparing Deepgram transcription",
            metadata: [
                "resumeHint": "If this job fails, retry transcription for the same track and source revision.",
            ]
        ))
        recordEvent(
            .info,
            name: "deepgram-transcription-started",
            message: "Deepgram transcription started.",
            request: request,
            fields: ["duration": String(format: "%.3f", request.inputAsset.duration)]
        )

        let transcript: TranscriptDocument
        if request.inputAsset.duration <= maximumSingleRequestDuration {
            transcript = try await transcribeWholeAsset(request, progress: progress)
        } else {
            transcript = try await transcribeChunkedAsset(request, progress: progress)
        }

        try Task.checkCancellation()
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .saving,
            fractionCompleted: 0.96,
            message: "Saving transcript",
            metadata: transcript.providerRequestID.map {
                ["providerRequestID": $0]
            } ?? [:]
        ))
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .completed,
            fractionCompleted: 1,
            message: "Transcript ready",
            metadata: transcript.providerRequestID.map {
                ["providerRequestID": $0]
            } ?? [:]
        ))
        recordEvent(
            .info,
            name: "deepgram-transcript-attached",
            message: "Deepgram transcript is ready to attach.",
            request: request,
            fields: [
                "segments": "\(transcript.segments.count)",
                "words": "\(transcript.words.count)",
            ]
        )

        return TranscriptionResult(
            requestID: request.id,
            transcript: transcript,
            summary: "Deepgram transcribed \(transcript.words.count) words"
        )
    }

    func cancel(requestID: UUID) async -> TranscriptionCancellationResult {
        await activeTasks.cancel(requestID: requestID)
        return .canceledRemotely
    }

    private func transcribeWholeAsset(
        _ request: TranscriptionRequest,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> TranscriptDocument {
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .uploading,
            fractionCompleted: 0.18,
            message: "Uploading audio to Deepgram",
            metadata: [
                "chunkCount": "1",
                "completedChunkCount": "0",
            ]
        ))
        let data = try await upload(
            fileURL: request.inputAsset.url,
            request: request,
            chunkIndex: nil
        )
        try Task.checkCancellation()
        let transcript = try DeepgramTranscriptParser.parse(
            data: data,
            request: request,
            providerIdentifier: identifier,
            providerDisplayName: displayName,
            providerModelName: modelName,
            sourceDuration: request.inputAsset.duration,
            offset: 0
        )
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .aligning,
            fractionCompleted: 0.86,
            message: "Parsing Deepgram transcript",
            metadata: transcript.providerRequestID.map {
                [
                    "chunkCount": "1",
                    "completedChunkCount": "1",
                    "providerRequestID": $0,
                ]
            } ?? [
                "chunkCount": "1",
                "completedChunkCount": "1",
            ]
        ))
        return transcript
    }

    private func transcribeChunkedAsset(
        _ request: TranscriptionRequest,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> TranscriptDocument {
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .preparing,
            fractionCompleted: 0.06,
            message: "Preparing transcript chunks",
            metadata: [
                "resumeHint": "Completed chunks will be reused if this long transcript job is retried.",
            ]
        ))

        let chunks = TranscriptionChunker.chunks(
            sourceDuration: request.inputAsset.duration,
            maximumChunkDuration: chunkDuration,
            contextOverlap: chunkContextOverlap
        )
        guard !chunks.isEmpty else {
            throw TranscriptionError.missingInput
        }
        let cachedChunkCount = await recoveryStore.cachedChunkCount(
            request: request,
            providerIdentifier: identifier,
            providerModelName: modelName,
            chunks: chunks
        )
        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .preparing,
            fractionCompleted: 0.08,
            message: cachedChunkCount > 0 ?
                "Prepared \(chunks.count) transcript chunks, \(cachedChunkCount) recoverable" :
                "Prepared \(chunks.count) transcript chunks",
            metadata: [
                "chunkCount": "\(chunks.count)",
                "completedChunkCount": "\(cachedChunkCount)",
                "resumeHint": cachedChunkCount > 0 ?
                    "Recovered completed chunks from a previous attempt." :
                    "Completed chunks will be cached for retry recovery.",
            ]
        ))
        let chunkFiles = try prepareChunkFiles(
            inputURL: request.inputAsset.url,
            chunks: chunks,
            requestID: request.id
        )
        defer {
            for chunkFile in chunkFiles {
                try? FileManager.default.removeItem(at: chunkFile.url)
            }
        }

        let transcripts = try await transcribeChunks(
            request: request,
            chunkFiles: chunkFiles,
            progress: progress
        )

        progress(TranscriptionProgress(
            requestID: request.id,
            stage: .aligning,
            fractionCompleted: 0.92,
            message: "Stitching transcript chunks",
            metadata: [
                "chunkCount": "\(chunks.count)",
                "completedChunkCount": "\(chunks.count)",
            ]
        ))
        return TranscriptStitcher.stitch(
            chunkTranscripts: transcripts,
            trackID: request.inputAsset.trackID,
            sourceRevision: request.inputAsset.sourceRevision,
            sourceDuration: request.inputAsset.duration,
            languageCode: request.preferredLanguageCode,
            providerIdentifier: identifier,
            providerDisplayName: displayName
        )
    }

    private func transcribeChunks(
        request: TranscriptionRequest,
        chunkFiles: [DeepgramChunkFile],
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> [(chunk: TranscriptionChunk, transcript: TranscriptDocument)] {
        var results = Array<TranscriptDocument?>(repeating: nil, count: chunkFiles.count)
        var nextIndex = 0
        var completedCount = 0
        let totalCount = max(chunkFiles.count, 1)
        let initialCount = min(maximumConcurrentChunks, chunkFiles.count)

        try await withThrowingTaskGroup(of: (Int, TranscriptDocument).self) { group in
            func enqueue(_ index: Int) {
                let chunkFile = chunkFiles[index]
                group.addTask { [self] in
                    try Task.checkCancellation()
                    if let cachedTranscript = await recoveryStore.transcript(
                        request: request,
                        providerIdentifier: identifier,
                        providerModelName: modelName,
                        chunk: chunkFile.chunk
                    ) {
                        recordEvent(
                            .info,
                            name: "deepgram-chunk-recovered",
                            message: "Recovered Deepgram transcript chunk from local cache.",
                            request: request,
                            fields: [
                                "chunk": "\(index + 1)",
                                "chunks": "\(totalCount)",
                                "words": "\(cachedTranscript.words.count)",
                            ]
                        )
                        return (index, cachedTranscript)
                    }

                    let uploadStartFraction = 0.10 + 0.72 * (Double(index) / Double(totalCount))
                    progress(TranscriptionProgress(
                        requestID: request.id,
                        stage: .uploading,
                        fractionCompleted: uploadStartFraction,
                        message: "Uploading transcript chunk \(index + 1)/\(totalCount)",
                        metadata: [
                            "chunkCount": "\(totalCount)",
                            "completedChunkCount": "0",
                        ]
                    ))
                    recordEvent(
                        .info,
                        name: "deepgram-chunk-uploading",
                        message: "Uploading Deepgram transcript chunk.",
                        request: request,
                        fields: [
                            "chunk": "\(index + 1)",
                            "chunks": "\(totalCount)",
                        ]
                    )
                    let data = try await upload(
                        fileURL: chunkFile.url,
                        request: request,
                        chunkIndex: index
                    )
                    try Task.checkCancellation()
                    let transcript = try DeepgramTranscriptParser.parse(
                        data: data,
                        request: request,
                        providerIdentifier: identifier,
                        providerDisplayName: displayName,
                        providerModelName: modelName,
                        sourceDuration: chunkFile.chunk.contextDuration,
                        offset: 0
                    )
                    await recoveryStore.store(
                        transcript,
                        request: request,
                        providerIdentifier: identifier,
                        providerModelName: modelName,
                        chunk: chunkFile.chunk
                    )
                    recordEvent(
                        .info,
                        name: "deepgram-chunk-completed",
                        message: "Deepgram transcript chunk completed.",
                        request: request,
                        fields: [
                            "chunk": "\(index + 1)",
                            "chunks": "\(totalCount)",
                            "words": "\(transcript.words.count)",
                        ]
                    )
                    return (index, transcript)
                }
            }

            for _ in 0..<initialCount {
                enqueue(nextIndex)
                nextIndex += 1
            }

            while let (index, transcript) = try await group.next() {
                results[index] = transcript
                completedCount += 1
                progress(TranscriptionProgress(
                    requestID: request.id,
                    stage: .transcribing,
                    fractionCompleted: 0.10 + 0.78 * (Double(completedCount) / Double(totalCount)),
                    message: "Transcribed chunk \(completedCount)/\(totalCount)",
                    metadata: {
                        var metadata = [
                            "chunkCount": "\(totalCount)",
                            "completedChunkCount": "\(completedCount)",
                        ]
                        if let providerRequestID = transcript.providerRequestID {
                            metadata["providerRequestID"] = providerRequestID
                        }
                        return metadata
                    }()
                ))
                if nextIndex < chunkFiles.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }
        }

        return try chunkFiles.enumerated().map { index, chunkFile in
            guard let transcript = results[index] else {
                throw TranscriptionError.invalidResponse("missing transcript for chunk \(index + 1)")
            }
            return (chunkFile.chunk, transcript)
        }
    }

    private func upload(
        fileURL: URL,
        request: TranscriptionRequest,
        chunkIndex: Int?
    ) async throws -> Data {
        var urlRequest = authenticatedListenRequest(
            contentType: contentType(for: fileURL),
            languageCode: request.preferredLanguageCode
        )
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120

        var attempt = 0
        while true {
            do {
                let (data, response) = try await performUpload(
                    urlRequest,
                    fileURL: fileURL,
                    requestID: request.id
                )
                try Task.checkCancellation()
                try validateHTTPResponse(response, data: data)
                return data
            } catch is CancellationError {
                recordEvent(
                    .info,
                    name: "deepgram-transcription-canceled",
                    message: "Deepgram transcription was canceled.",
                    request: request,
                    fields: chunkIndex.map { ["chunk": "\($0 + 1)"] } ?? [:]
                )
                throw CancellationError()
            } catch {
                guard attempt < maximumRetryCount, shouldRetry(error) else {
                    recordEvent(
                        .severe,
                        name: "deepgram-provider-error",
                        message: "Deepgram transcription request failed.",
                        request: request,
                        fields: [
                            "error": error.localizedDescription,
                            "chunk": chunkIndex.map { "\($0 + 1)" } ?? "",
                            "attempt": "\(attempt + 1)",
                        ]
                    )
                    throw error
                }

                attempt += 1
                let delay = retryDelayNanoseconds(attempt: attempt)
                recordEvent(
                    .warning,
                    name: "deepgram-provider-retry",
                    message: "Retrying transient Deepgram transcription failure.",
                    request: request,
                    fields: [
                        "error": error.localizedDescription,
                        "chunk": chunkIndex.map { "\($0 + 1)" } ?? "",
                        "attempt": "\(attempt)",
                    ]
                )
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func performUpload(
        _ request: URLRequest,
        fileURL: URL,
        requestID: UUID
    ) async throws -> (Data, URLResponse) {
        final class Box: @unchecked Sendable {
            var task: URLSessionUploadTask?
        }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                    Task { await self.activeTasks.unregister(task: box.task, requestID: requestID) }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: TranscriptionError.invalidResponse("missing response data"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                box.task = task
                Task { await self.activeTasks.register(task: task, requestID: requestID) }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
            Task { await self.activeTasks.cancel(requestID: requestID) }
        }
    }

    private func prepareChunkFiles(
        inputURL: URL,
        chunks: [TranscriptionChunk],
        requestID: UUID
    ) throws -> [DeepgramChunkFile] {
        guard WAVAudioDecoder.canDecode(inputURL) else {
            throw TranscriptionError.unsupportedLongFormChunking(
                "Long-form Deepgram transcription currently needs Soundtime's editable WAV/proxy file."
            )
        }

        let fileInfo = try WAVAudioDecoder.inspect(url: inputURL)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Soundtime-Deepgram-\(requestID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        return try chunks.map { chunk in
            let startFrame = min(
                max(Int((chunk.contextStartTime * fileInfo.sampleRate).rounded(.down)), 0),
                fileInfo.frameCount
            )
            let endFrame = min(
                max(Int((chunk.contextEndTime * fileInfo.sampleRate).rounded(.up)), startFrame),
                fileInfo.frameCount
            )
            let chunkURL = temporaryDirectory
                .appendingPathComponent("chunk-\(chunk.index + 1)-of-\(chunks.count).wav")
            let chunkBuffer = try WAVAudioDecoder.decode(url: inputURL, frameRange: startFrame..<endFrame)
            try WAVFileWriter.write(chunkBuffer, to: chunkURL)
            return DeepgramChunkFile(chunk: chunk, url: chunkURL)
        }
    }

    private func authenticatedListenRequest(
        contentType: String,
        languageCode: String?
    ) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/listen"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [
            URLQueryItem(name: "model", value: modelName),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "diarize_model", value: "latest"),
        ]
        if let languageCode, !languageCode.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav", "wave":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a", "mp4", "aac":
            return "audio/mp4"
        case "aif", "aiff":
            return "audio/aiff"
        case "flac":
            return "audio/flac"
        case "ogg", "oga":
            return "audio/ogg"
        default:
            return "application/octet-stream"
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ??
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw TranscriptionError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case let .httpError(statusCode, _):
                return statusCode == 429 || statusCode == 504 || (500..<600).contains(statusCode)
            case .missingAPIKey, .missingInput, .invalidResponse, .unsupportedLongFormChunking:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
    }

    private func retryDelayNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(pow(2.0, Double(max(attempt - 1, 0))) * 0.75, 6)
        return UInt64(seconds * 1_000_000_000)
    }

    private func recordEvent(
        _ severity: SoundtimeDiagnosticSeverity,
        name: String,
        message: String,
        request: TranscriptionRequest,
        fields: [String: String] = [:]
    ) {
        var mergedFields = fields
        mergedFields["requestID"] = request.id.uuidString
        mergedFields["trackID"] = request.inputAsset.trackID?.uuidString ?? ""
        mergedFields["provider"] = identifier
        SoundtimeDiagnostics.shared.record(
            category: .api,
            severity: severity,
            name: name,
            message: message,
            fields: mergedFields
        )
        Task { @MainActor in
            PerformanceDashboardWindowController.refreshIfVisible()
        }
    }
}

enum DeepgramTranscriptParser {
    static func parse(
        data: Data,
        request: TranscriptionRequest,
        providerIdentifier: String,
        providerDisplayName: String,
        providerModelName: String,
        sourceDuration: TimeInterval,
        offset: TimeInterval
    ) throws -> TranscriptDocument {
        let response: DeepgramListenResponse
        do {
            response = try JSONDecoder().decode(DeepgramListenResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            throw DeepgramTranscriptionProvider.TranscriptionError.invalidResponse(
                "\(error.localizedDescription): \(body)"
            )
        }

        let channel = response.results.channels.first
        let alternative = channel?.alternatives.first
        let fallbackWords = alternative?.words ?? []
        let utterances = response.results.utterances ?? []
        let segments: [TranscriptSegment]
        if utterances.isEmpty {
            segments = makeSegmentsFromWords(
                fallbackWords,
                channelIndex: channel?.channelIndex,
                offset: offset,
                sourceDuration: sourceDuration
            )
        } else {
            segments = utterances.map {
                makeSegment(
                    from: $0,
                    fallbackChannelIndex: channel?.channelIndex,
                    offset: offset,
                    sourceDuration: sourceDuration
                )
            }.filter { !$0.words.isEmpty || !$0.text.isEmpty }
        }

        return TranscriptDocument(
            sourceKind: .track,
            trackID: request.inputAsset.trackID,
            sourceRevision: request.inputAsset.sourceRevision,
            sourceDuration: sourceDuration,
            languageCode: request.preferredLanguageCode ?? response.metadata?.language,
            providerIdentifier: providerIdentifier,
            providerDisplayName: providerDisplayName,
            providerRequestID: response.metadata?.requestID,
            providerModelName: providerModelName,
            segments: segments
        )
    }

    private static func makeSegmentsFromWords(
        _ words: [DeepgramWord],
        channelIndex: Int?,
        offset: TimeInterval,
        sourceDuration: TimeInterval
    ) -> [TranscriptSegment] {
        let transcriptWords = words.map {
            makeWord(
                from: $0,
                fallbackChannelIndex: channelIndex,
                offset: offset,
                sourceDuration: sourceDuration
            )
        }
        guard !transcriptWords.isEmpty else {
            return []
        }

        var segments: [TranscriptSegment] = []
        var currentWords: [TranscriptWord] = []
        for word in transcriptWords {
            if let previousWord = currentWords.last,
               previousWord.speakerID != word.speakerID ||
                word.startTime - previousWord.endTime > 1.25 ||
                currentWords.count >= 42
            {
                segments.append(segment(from: currentWords))
                currentWords.removeAll(keepingCapacity: true)
            }
            currentWords.append(word)
        }
        if !currentWords.isEmpty {
            segments.append(segment(from: currentWords))
        }
        return segments
    }

    private static func makeSegment(
        from utterance: DeepgramUtterance,
        fallbackChannelIndex: Int?,
        offset: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TranscriptSegment {
        let speakerID = speakerID(utterance.speaker)
        let channelIndex = utterance.channelIndex ?? fallbackChannelIndex
        let words = (utterance.words ?? []).map {
            makeWord(
                from: $0,
                fallbackSpeakerID: speakerID,
                fallbackSpeakerConfidence: utterance.speakerConfidence,
                fallbackChannelIndex: channelIndex,
                offset: offset,
                sourceDuration: sourceDuration
            )
        }
        let startTime = clampTime(utterance.start + offset, sourceDuration: sourceDuration)
        let endTime = clampTime(utterance.end + offset, sourceDuration: sourceDuration)
        return TranscriptSegment(
            speakerID: speakerID,
            speakerLabel: speakerID.map(speakerLabel),
            startTime: words.first?.startTime ?? startTime,
            endTime: words.last?.endTime ?? max(endTime, startTime),
            text: utterance.transcript,
            words: words,
            confidence: utterance.confidence,
            speakerConfidence: utterance.speakerConfidence,
            channelIndex: channelIndex
        )
    }

    private static func segment(from words: [TranscriptWord]) -> TranscriptSegment {
        TranscriptSegment(
            speakerID: words.first?.speakerID,
            speakerLabel: words.first?.speakerID.map(speakerLabel),
            startTime: words.first?.startTime ?? 0,
            endTime: words.last?.endTime ?? 0,
            text: words.map(\.text).joined(separator: " "),
            words: words,
            confidence: meanConfidence(words.map(\.confidence)),
            speakerConfidence: meanConfidence(words.map(\.speakerConfidence)),
            channelIndex: words.first?.channelIndex
        )
    }

    private static func makeWord(
        from word: DeepgramWord,
        fallbackSpeakerID: String? = nil,
        fallbackSpeakerConfidence: Float? = nil,
        fallbackChannelIndex: Int?,
        offset: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TranscriptWord {
        let punctuatedText = normalized(word.punctuatedWord)
        let rawText = normalized(word.word)
        let text = punctuatedText ?? rawText ?? ""
        return TranscriptWord(
            text: text,
            rawText: rawText,
            punctuatedText: punctuatedText,
            startTime: clampTime(word.start + offset, sourceDuration: sourceDuration),
            endTime: clampTime(word.end + offset, sourceDuration: sourceDuration),
            confidence: word.confidence,
            speakerID: speakerID(word.speaker) ?? fallbackSpeakerID,
            speakerConfidence: word.speakerConfidence ?? fallbackSpeakerConfidence,
            channelIndex: word.channelIndex ?? fallbackChannelIndex
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func speakerID(_ value: String?) -> String? {
        guard let value = normalized(value) else {
            return nil
        }
        return value.hasPrefix("speaker-") ? value : "speaker-\(value)"
    }

    private static func speakerLabel(_ speakerID: String) -> String {
        let suffix = speakerID
            .replacingOccurrences(of: "speaker-", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return suffix.isEmpty ? "Speaker" : "Speaker \(suffix)"
    }

    private static func meanConfidence(_ values: [Float?]) -> Float? {
        let resolved = values.compactMap { $0 }
        guard !resolved.isEmpty else {
            return nil
        }
        return resolved.reduce(0, +) / Float(resolved.count)
    }

    private static func clampTime(_ value: TimeInterval, sourceDuration: TimeInterval) -> TimeInterval {
        min(max(value, 0), max(sourceDuration, 0))
    }
}

private struct DeepgramChunkFile {
    let chunk: TranscriptionChunk
    let url: URL
}

private actor DeepgramURLSessionTaskRegistry {
    private var tasksByRequestID: [UUID: [URLSessionTask]] = [:]

    func register(task: URLSessionTask, requestID: UUID) {
        tasksByRequestID[requestID, default: []].append(task)
    }

    func unregister(task: URLSessionTask?, requestID: UUID) {
        guard let task else {
            return
        }
        tasksByRequestID[requestID]?.removeAll { $0 === task }
        if tasksByRequestID[requestID]?.isEmpty == true {
            tasksByRequestID.removeValue(forKey: requestID)
        }
    }

    func cancel(requestID: UUID) {
        let tasks = tasksByRequestID.removeValue(forKey: requestID) ?? []
        for task in tasks {
            task.cancel()
        }
    }
}

private struct DeepgramListenResponse: Decodable {
    let metadata: DeepgramMetadata?
    let results: DeepgramResults
}

private struct DeepgramMetadata: Decodable {
    let requestID: String?
    let language: String?

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case language
    }
}

private struct DeepgramResults: Decodable {
    let channels: [DeepgramChannel]
    let utterances: [DeepgramUtterance]?
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]
    let channelIndex: Int?

    private enum CodingKeys: String, CodingKey {
        case alternatives
        case channelIndex = "channel_index"
        case channel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alternatives = try container.decodeIfPresent([DeepgramAlternative].self, forKey: .alternatives) ?? []
        channelIndex = try container.decodeIfPresent(Int.self, forKey: .channelIndex) ??
            container.decodeFlexibleChannelIndex(forKey: .channel)
    }
}

private struct DeepgramAlternative: Decodable {
    let transcript: String?
    let confidence: Float?
    let words: [DeepgramWord]?
}

private struct DeepgramUtterance: Decodable {
    let start: TimeInterval
    let end: TimeInterval
    let transcript: String
    let confidence: Float?
    let speaker: String?
    let speakerConfidence: Float?
    let channelIndex: Int?
    let words: [DeepgramWord]?

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case transcript
        case confidence
        case speaker
        case speakerConfidence = "speaker_confidence"
        case channelIndex = "channel_index"
        case channel
        case words
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
        end = try container.decodeIfPresent(TimeInterval.self, forKey: .end) ?? start
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        confidence = try container.decodeIfPresent(Float.self, forKey: .confidence)
        speaker = try container.decodeFlexibleString(forKey: .speaker)
        speakerConfidence = try container.decodeIfPresent(Float.self, forKey: .speakerConfidence)
        channelIndex = try container.decodeIfPresent(Int.self, forKey: .channelIndex) ??
            container.decodeFlexibleChannelIndex(forKey: .channel)
        words = try container.decodeIfPresent([DeepgramWord].self, forKey: .words)
    }
}

private struct DeepgramWord: Decodable {
    let word: String?
    let punctuatedWord: String?
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float?
    let speaker: String?
    let speakerConfidence: Float?
    let channelIndex: Int?

    private enum CodingKeys: String, CodingKey {
        case word
        case punctuatedWord = "punctuated_word"
        case start
        case end
        case confidence
        case speaker
        case speakerConfidence = "speaker_confidence"
        case channelIndex = "channel_index"
        case channel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decodeIfPresent(String.self, forKey: .word)
        punctuatedWord = try container.decodeIfPresent(String.self, forKey: .punctuatedWord)
        start = try container.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
        end = try container.decodeIfPresent(TimeInterval.self, forKey: .end) ?? start
        confidence = try container.decodeIfPresent(Float.self, forKey: .confidence)
        speaker = try container.decodeFlexibleString(forKey: .speaker)
        speakerConfidence = try container.decodeIfPresent(Float.self, forKey: .speakerConfidence)
        channelIndex = try container.decodeIfPresent(Int.self, forKey: .channelIndex) ??
            container.decodeFlexibleChannelIndex(forKey: .channel)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return "\(value)"
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(format: "%.0f", value)
        }
        return nil
    }

    func decodeFlexibleChannelIndex(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let values = try? decodeIfPresent([Int].self, forKey: key) {
            return values.first
        }
        return nil
    }
}
