import Foundation

final class AudioShakeAudioProcessingProvider: AudioProcessingProvider, @unchecked Sendable {
    enum ProcessingError: LocalizedError {
        case unsupportedOperation
        case missingAPIKey
        case missingInput
        case failedToCreateOutputDirectory
        case invalidResponse(String)
        case httpError(statusCode: Int, body: String)
        case taskTimedOut
        case targetFailed(String)
        case missingOutput
        case invalidDownloadURL(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedOperation:
                "AudioShake processing does not support this operation yet."
            case .missingAPIKey:
                "Add an AudioShake API key in Preferences before using AudioShake processing."
            case .missingInput:
                "There is no audio asset to send to AudioShake."
            case .failedToCreateOutputDirectory:
                "Could not create the AudioShake output folder."
            case let .invalidResponse(message):
                "AudioShake returned an unexpected response: \(message)"
            case let .httpError(statusCode, body):
                "AudioShake request failed (\(statusCode)): \(body)"
            case .taskTimedOut:
                "AudioShake processing timed out before the task completed."
            case let .targetFailed(message):
                "AudioShake processing failed: \(message)"
            case .missingOutput:
                "AudioShake completed but did not return a downloadable WAV output."
            case let .invalidDownloadURL(value):
                "AudioShake returned an invalid download URL: \(value)"
            }
        }
    }

    var identifier: String {
        switch preferredOperation {
        case .denoise:
            return "audioshake.speech-clarity"
        case .separateMusicStems:
            return "audioshake.music-stems"
        }
    }

    var displayName: String {
        switch preferredOperation {
        case .denoise:
            return "AudioShake Speech Clarity"
        case .separateMusicStems:
            return "AudioShake Music Stems"
        }
    }

    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL
    private let pollInterval: Duration
    private let timeout: Duration
    private let preferredOperation: AudioProcessingOperation

    init?(
        preferredOperation: AudioProcessingOperation = .denoise,
        apiKey: String? = AudioProcessingCredentials.audioShakeAPIKey(),
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.audioshake.ai")!,
        pollInterval: Duration = .seconds(5),
        timeout: Duration = .seconds(15 * 60)
    ) {
        guard let apiKey, !apiKey.isEmpty else {
            return nil
        }

        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.preferredOperation = preferredOperation
    }

    func process(
        _ request: AudioProcessingRequest,
        progress: @escaping AudioProcessingProgressHandler
    ) async throws -> AudioProcessingResult {
        guard request.operation == .denoise || request.operation == .separateMusicStems else {
            throw ProcessingError.unsupportedOperation
        }
        guard !request.inputAssets.isEmpty else {
            throw ProcessingError.missingInput
        }

        do {
            try FileManager.default.createDirectory(
                at: request.outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProcessingError.failedToCreateOutputDirectory
        }

        var outputAssets: [AudioProcessingOutputAsset] = []
        outputAssets.reserveCapacity(request.inputAssets.count)

        for inputAsset in request.inputAssets {
            try Task.checkCancellation()
            progress(AudioProcessingProgress(
                requestID: request.id,
                stage: .uploading,
                fractionCompleted: 0.12,
                message: "uploading audio to AudioShake"
            ))
            let asset = try await uploadAsset(inputAsset, requestID: request.id)
            try Task.checkCancellation()
            progress(AudioProcessingProgress(
                requestID: request.id,
                stage: .queued,
                fractionCompleted: 0.24,
                message: "submitting AudioShake task"
            ))
            let task = try await createTask(assetID: asset.id, request: request, inputAsset: inputAsset)
            try Task.checkCancellation()
            let completedTask = try await pollTaskUntilFinished(task.id, requestID: request.id, progress: progress)
            try Task.checkCancellation()
            let outputs = try outputs(for: request.operation, in: completedTask)
            progress(AudioProcessingProgress(
                requestID: request.id,
                stage: .downloading,
                fractionCompleted: 0.88,
                message: request.operation == .denoise ? "downloading denoised audio" : "downloading separated stems"
            ))
            for output in outputs {
                let outputURL = outputURL(for: inputAsset, request: request, output: output)
                try await downloadOutput(output.asset, to: outputURL)
                try Task.checkCancellation()
                let decodedOutput = try WAVAudioDecoder.decode(url: outputURL)
                outputAssets.append(AudioProcessingOutputAsset(
                    inputAssetID: inputAsset.id,
                    url: outputURL,
                    displayName: output.displayName,
                    sampleRate: decodedOutput.sampleRate,
                    channelCount: decodedOutput.channelCount,
                    frameCount: decodedOutput.frameCount
                ))
            }
        }

        let operationSummary = request.operation == .denoise ? "denoised" : "separated"
        let result = AudioProcessingResult(
            requestID: request.id,
            outputAssets: outputAssets,
            summary: "AudioShake \(operationSummary) \(outputAssets.count) asset\(outputAssets.count == 1 ? "" : "s")"
        )
        progress(AudioProcessingProgress(
            requestID: request.id,
            stage: .completed,
            fractionCompleted: 1,
            message: result.summary
        ))
        return result
    }

    func cancel(requestID: UUID) async -> AudioProcessingCancellationResult {
        .remoteCancellationUnsupported
    }

    private func uploadAsset(
        _ inputAsset: AudioProcessingInputAsset,
        requestID: UUID
    ) async throws -> AudioShakeAssetResponse {
        let boundary = "SoundtimeBoundary-\(UUID().uuidString)"
        let multipartURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Soundtime-AudioShake-\(requestID.uuidString)-\(inputAsset.id.uuidString).multipart")
        try writeMultipartFileUploadBody(
            inputFileURL: inputAsset.url,
            fieldName: "file",
            boundary: boundary,
            destinationURL: multipartURL
        )
        defer {
            try? FileManager.default.removeItem(at: multipartURL)
        }

        var urlRequest = authenticatedRequest(path: "assets")
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let (data, response) = try await session.upload(for: urlRequest, fromFile: multipartURL)
        try Task.checkCancellation()
        try validateHTTPResponse(response, data: data)
        return try decode(AudioShakeAssetResponse.self, from: data)
    }

    private func createTask(
        assetID: String,
        request: AudioProcessingRequest,
        inputAsset: AudioProcessingInputAsset
    ) async throws -> AudioShakeTaskResponse {
        var urlRequest = authenticatedRequest(path: "tasks")
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(AudioShakeCreateTaskRequest(
            assetId: assetID,
            targets: targets(for: request.operation),
            metadata: audioShakeMetadata(request: request, inputAsset: inputAsset)
        ))

        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()
        try validateHTTPResponse(response, data: data)
        return try decode(AudioShakeTaskResponse.self, from: data)
    }

    private func targets(for operation: AudioProcessingOperation) -> [AudioShakeCreateTaskTarget] {
        switch operation {
        case .denoise:
            return [
                AudioShakeCreateTaskTarget(model: "speech_clarity", formats: ["wav"]),
            ]
        case .separateMusicStems:
            return [
                AudioShakeCreateTaskTarget(model: "vocals", formats: ["wav"]),
                AudioShakeCreateTaskTarget(model: "drums", formats: ["wav"]),
                AudioShakeCreateTaskTarget(model: "bass", formats: ["wav"]),
                AudioShakeCreateTaskTarget(model: "other", formats: ["wav"]),
            ]
        }
    }

    private func pollTaskUntilFinished(
        _ taskID: String,
        requestID: UUID,
        progress: @escaping AudioProcessingProgressHandler
    ) async throws -> AudioShakeTaskResponse {
        let started = ContinuousClock.now
        var currentTask = try await fetchTask(taskID)
        while true {
            try Task.checkCancellation()
            let elapsed = started.duration(to: .now)
            let progressFraction = min(max(0.32 + Double(elapsed.components.seconds) / Double(timeout.components.seconds) * 0.5, 0.32), 0.82)
            progress(AudioProcessingProgress(
                requestID: requestID,
                stage: .processing,
                fractionCompleted: progressFraction,
                message: targetStatusSummary(in: currentTask)
            ))
            if currentTask.targets.allSatisfy(\.isTerminal) {
                return currentTask
            }

            guard elapsed < timeout else {
                throw ProcessingError.taskTimedOut
            }

            try await Task.sleep(for: pollInterval)
            currentTask = try await fetchTask(taskID)
        }
    }

    private func fetchTask(_ taskID: String) async throws -> AudioShakeTaskResponse {
        let path = "tasks/\(taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskID)"
        var urlRequest = authenticatedRequest(path: path)
        urlRequest.httpMethod = "GET"

        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()
        try validateHTTPResponse(response, data: data)
        return try decode(AudioShakeTaskResponse.self, from: data)
    }

    private struct NamedAudioShakeOutput {
        let displayName: String
        let asset: AudioShakeTaskOutput
    }

    private func outputs(
        for operation: AudioProcessingOperation,
        in task: AudioShakeTaskResponse
    ) throws -> [NamedAudioShakeOutput] {
        switch operation {
        case .denoise:
            let output = try outputForTarget(model: "speech_clarity", in: task) ?? outputForFirstCompletedTarget(in: task)
            return [NamedAudioShakeOutput(
                displayName: output.name ?? "Denoised",
                asset: output
            )]
        case .separateMusicStems:
            let preferredOrder = ["vocals", "drums", "bass", "other"]
            let outputs = try preferredOrder.compactMap { model -> NamedAudioShakeOutput? in
                guard let output = try outputForTarget(model: model, in: task) else {
                    return nil
                }
                return NamedAudioShakeOutput(
                    displayName: output.name ?? Self.displayName(forStemModel: model),
                    asset: output
                )
            }
            guard !outputs.isEmpty else {
                return try task.targets.map { target in
                    let output = try outputForCompletedTarget(target)
                    return NamedAudioShakeOutput(
                        displayName: output.name ?? Self.displayName(forStemModel: target.model),
                        asset: output
                    )
                }
            }
            return outputs
        }
    }

    private func outputForTarget(model: String, in task: AudioShakeTaskResponse) throws -> AudioShakeTaskOutput? {
        guard let target = task.targets.first(where: { $0.model == model }) else {
            return nil
        }
        return try outputForCompletedTarget(target)
    }

    private func outputForFirstCompletedTarget(in task: AudioShakeTaskResponse) throws -> AudioShakeTaskOutput {
        guard let target = task.targets.first else {
            throw ProcessingError.missingOutput
        }
        return try outputForCompletedTarget(target)
    }

    private func outputForCompletedTarget(_ target: AudioShakeTaskTarget) throws -> AudioShakeTaskOutput {
        if target.status == "error" {
            throw ProcessingError.targetFailed(target.error?.message ?? "unknown provider error")
        }
        guard target.isCompleted else {
            throw ProcessingError.invalidResponse("task target is not completed")
        }
        guard
            let output = target.output.first(where: { $0.format.lowercased() == "wav" }) ??
                target.output.first
        else {
            throw ProcessingError.missingOutput
        }

        return output
    }

    private static func displayName(forStemModel model: String) -> String {
        switch model.lowercased() {
        case "vocals", "vocal":
            return "Vocals"
        case "drums":
            return "Drums"
        case "bass":
            return "Bass"
        case "other":
            return "Other"
        default:
            return model
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { word in word.prefix(1).uppercased() + word.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func downloadOutput(_ output: AudioShakeTaskOutput, to destinationURL: URL) async throws {
        guard let downloadURL = URL(string: output.link) else {
            throw ProcessingError.invalidDownloadURL(output.link)
        }

        let (temporaryURL, response) = try await session.download(from: downloadURL)
        try Task.checkCancellation()
        try validateHTTPResponse(response, data: nil)

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func authenticatedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 60
        return request
    }

    private func targetStatusSummary(in task: AudioShakeTaskResponse) -> String {
        let statuses = task.targets
            .map { target in
                let status = target.status ?? (target.output.isEmpty ? "processing" : "completed")
                return "\(target.model): \(status)"
            }
            .joined(separator: ", ")
        return statuses.isEmpty ? "AudioShake processing" : statuses
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProcessingError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ProcessingError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            throw ProcessingError.invalidResponse("\(error.localizedDescription): \(body)")
        }
    }

    private func outputURL(
        for inputAsset: AudioProcessingInputAsset,
        request: AudioProcessingRequest,
        output: NamedAudioShakeOutput
    ) -> URL {
        let safeName = inputAsset.displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let safeOutputName = output.displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let sourceStem = safeName.isEmpty ? "AudioShake" : safeName
        let operationStem = request.operation == .denoise ? "Denoised" : (safeOutputName.isEmpty ? "Stem" : safeOutputName)
        return request.outputDirectory
            .appendingPathComponent("\(sourceStem)-AudioShake-\(operationStem)-\(UUID().uuidString).wav")
            .standardizedFileURL
    }

    private func audioShakeMetadata(
        request: AudioProcessingRequest,
        inputAsset: AudioProcessingInputAsset
    ) -> String {
        [
            "app": "Soundtime",
            "requestID": request.id.uuidString,
            "operation": request.operation.rawValue,
            "inputAssetID": inputAsset.id.uuidString,
            "trackID": inputAsset.trackID?.uuidString ?? "",
        ]
        .map { "\($0.key)=\($0.value)" }
        .sorted()
        .joined(separator: ";")
    }

    private func writeMultipartFileUploadBody(
        inputFileURL: URL,
        fieldName: String,
        boundary: String,
        destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destinationURL)
        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? outputHandle.close()
        }

        let filename = inputFileURL.lastPathComponent.isEmpty ? "soundtime-input.wav" : inputFileURL.lastPathComponent
        let header = """
        --\(boundary)\r
        Content-Disposition: form-data; name="\(fieldName)"; filename="\(filename)"\r
        Content-Type: audio/wav\r
        \r

        """
        try outputHandle.write(contentsOf: Data(header.utf8))

        let inputHandle = try FileHandle(forReadingFrom: inputFileURL)
        defer {
            try? inputHandle.close()
        }

        while true {
            let chunk = try inputHandle.read(upToCount: 1_048_576)
            guard let chunk, !chunk.isEmpty else {
                break
            }
            try outputHandle.write(contentsOf: chunk)
        }

        let footer = "\r\n--\(boundary)--\r\n"
        try outputHandle.write(contentsOf: Data(footer.utf8))
    }
}

private struct AudioShakeAssetResponse: Decodable {
    let id: String
    let format: String?
    let name: String?
}

private struct AudioShakeCreateTaskRequest: Encodable {
    let assetId: String
    let targets: [AudioShakeCreateTaskTarget]
    let metadata: String
}

private struct AudioShakeCreateTaskTarget: Encodable {
    let model: String
    let formats: [String]
}

private struct AudioShakeTaskResponse: Decodable {
    let id: String
    let targets: [AudioShakeTaskTarget]
}

private struct AudioShakeTaskTarget: Decodable {
    let id: String?
    let model: String
    let status: String?
    let output: [AudioShakeTaskOutput]
    let error: AudioShakeTaskError?

    var isCompleted: Bool {
        status == "completed" || (status == nil && !output.isEmpty)
    }

    var isTerminal: Bool {
        isCompleted || status == "error"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case status
        case output
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        model = try container.decode(String.self, forKey: .model)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        output = try container.decodeIfPresent([AudioShakeTaskOutput].self, forKey: .output) ?? []
        error = try container.decodeIfPresent(AudioShakeTaskError.self, forKey: .error)
    }
}

private struct AudioShakeTaskOutput: Decodable {
    let name: String?
    let format: String
    let link: String
}

private struct AudioShakeTaskError: Decodable {
    let code: Int?
    let message: String?
}

enum AudioProcessingProviderFactory {
    static func makeDenoiseProvider() -> AudioProcessingProvider {
        AudioShakeAudioProcessingProvider(preferredOperation: .denoise) ?? LocalDenoiseAudioProcessingProvider()
    }

    static func makeMusicStemProvider() throws -> AudioProcessingProvider {
        guard let provider = AudioShakeAudioProcessingProvider(preferredOperation: .separateMusicStems) else {
            throw AudioShakeAudioProcessingProvider.ProcessingError.missingAPIKey
        }
        return provider
    }

    static func denoiseProviderDisplayName() -> String {
        if let provider = AudioShakeAudioProcessingProvider(preferredOperation: .denoise) {
            return provider.displayName
        }
        return LocalDenoiseAudioProcessingProvider().displayName
    }
}
