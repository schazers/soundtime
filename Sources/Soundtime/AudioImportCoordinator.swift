import Foundation

struct AudioImportAdmission: Sendable {
    let sessionID: UUID
    let assetID: UUID
    let sourceURL: URL
    let assetInfo: AudioAssetInfo
    let fingerprint: AudioImportFingerprint
    let cachedImport: CachedAudioImport?
    let admissionMilliseconds: Double

    var initialStage: AudioImportStage {
        cachedImport == nil ? .admitted : .editableReady
    }
}

actor AudioImportCoordinator {
    static let shared = AudioImportCoordinator()

    private struct Session {
        let admission: AudioImportAdmission
        var stage: AudioImportStage
        var progress: Double
        var message: String
        var task: Task<AudioAssetProxyResult, Error>?
    }

    private var sessions: [UUID: Session] = [:]

    init() {
        AudioImportCacheStore.shared.cleanStaleTransactions()
    }

    func admit(
        sourceURL: URL,
        assetID: UUID = UUID()
    ) async throws -> AudioImportAdmission {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let normalizedURL = sourceURL.standardizedFileURL
        let assetInfo = try await AudioAssetImporter.inspect(url: normalizedURL)
        try Task.checkCancellation()
        let fingerprint = try AudioImportFingerprint(
            url: normalizedURL,
            assetInfo: assetInfo
        )
        let cachedImport = AudioImportCacheStore.shared.cachedImport(
            for: fingerprint,
            sourceURL: normalizedURL
        )
        let admission = AudioImportAdmission(
            sessionID: UUID(),
            assetID: assetID,
            sourceURL: normalizedURL,
            assetInfo: assetInfo,
            fingerprint: fingerprint,
            cachedImport: cachedImport,
            admissionMilliseconds: Double(
                DispatchTime.now().uptimeNanoseconds &- startedAt
            ) / 1_000_000
        )
        sessions[admission.sessionID] = Session(
            admission: admission,
            stage: admission.initialStage,
            progress: cachedImport == nil ? 0 : 1,
            message: cachedImport == nil ? "Audio admitted" : "Cached editable audio ready",
            task: nil
        )
        return admission
    }

    func startPreparingEditableAsset(
        admission: AudioImportAdmission,
        progress uiProgress: (@Sendable (AudioImportProgress) -> Void)? = nil
    ) -> Task<AudioAssetProxyResult, Error> {
        if let existing = sessions[admission.sessionID]?.task {
            return existing
        }

        let sessionID = admission.sessionID
        let task = Task.detached(priority: .utility) {
            try await AudioAssetImporter.importEditableAsset(
                admission: admission
            ) { progress in
                uiProgress?(progress)
                Task {
                    await AudioImportCoordinator.shared.record(
                        progress,
                        for: sessionID
                    )
                }
            }
        }
        sessions[sessionID]?.task = task
        sessions[sessionID]?.stage = .proxying
        sessions[sessionID]?.message = "Preparing editable audio"

        Task {
            let result = await task.result
            complete(sessionID: sessionID, result: result)
        }
        return task
    }

    func cancel(sessionID: UUID) {
        guard var session = sessions[sessionID] else {
            return
        }
        session.task?.cancel()
        session.stage = .canceled
        session.message = "Import canceled"
        session.task = nil
        sessions[sessionID] = session
    }

    func forget(sessionID: UUID) {
        sessions[sessionID]?.task?.cancel()
        sessions[sessionID] = nil
    }

    func snapshot(sessionID: UUID) -> AudioImportSessionSnapshot? {
        guard let session = sessions[sessionID] else {
            return nil
        }
        return AudioImportSessionSnapshot(
            id: sessionID,
            assetID: session.admission.assetID,
            sourceURL: session.admission.sourceURL,
            stage: session.stage,
            progress: session.progress,
            message: session.message
        )
    }

    func activeSnapshots() -> [AudioImportSessionSnapshot] {
        sessions.values
            .filter { !$0.stage.isTerminal }
            .map { session in
                AudioImportSessionSnapshot(
                    id: session.admission.sessionID,
                    assetID: session.admission.assetID,
                    sourceURL: session.admission.sourceURL,
                    stage: session.stage,
                    progress: session.progress,
                    message: session.message
                )
            }
    }

    private func record(
        _ progress: AudioImportProgress,
        for sessionID: UUID
    ) {
        guard var session = sessions[sessionID], session.stage != .canceled else {
            return
        }
        session.stage = progress.stage
        session.progress = progress.fraction
        session.message = progress.message
        sessions[sessionID] = session
    }

    private func complete(
        sessionID: UUID,
        result: Result<AudioAssetProxyResult, Error>
    ) {
        guard var session = sessions[sessionID], session.stage != .canceled else {
            return
        }
        session.task = nil
        switch result {
        case .success:
            session.stage = .complete
            session.progress = 1
            session.message = "Import complete"
        case let .failure(error):
            if error is CancellationError {
                session.stage = .canceled
                session.message = "Import canceled"
            } else {
                session.stage = .failed
                session.message = error.localizedDescription
            }
        }
        sessions[sessionID] = session
    }
}
