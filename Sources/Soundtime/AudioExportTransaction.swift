import Darwin
import Foundation

struct AudioExportFileTransaction {
    enum TransactionError: LocalizedError {
        case couldNotCreateStagingDirectory
        case missingStagedOutput
        case commitFailed(URL, POSIXErrorCode)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateStagingDirectory:
                return "The export staging directory could not be created."
            case .missingStagedOutput:
                return "The completed export could not be found before it was committed."
            case let .commitFailed(url, code):
                return "The export could not replace \(url.lastPathComponent): \(POSIXError(code).localizedDescription)"
            }
        }
    }

    let finalURL: URL
    let stagingURL: URL

    init(finalURL: URL) throws {
        self.finalURL = finalURL.standardizedFileURL
        let parentURL = self.finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        guard FileManager.default.fileExists(atPath: parentURL.path) else {
            throw TransactionError.couldNotCreateStagingDirectory
        }

        let extensionSuffix = self.finalURL.pathExtension.isEmpty ?
            "" :
            ".\(self.finalURL.pathExtension)"
        stagingURL = parentURL.appendingPathComponent(
            ".soundtime-export-\(UUID().uuidString).partial\(extensionSuffix)"
        )
    }

    func commit() throws -> URL {
        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            throw TransactionError.missingStagedOutput
        }

        let result = stagingURL.path.withCString { sourcePath in
            finalURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw TransactionError.commitFailed(
                finalURL,
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        Self.synchronizeDirectory(finalURL.deletingLastPathComponent())
        return finalURL
    }

    func cancel() {
        try? FileManager.default.removeItem(at: stagingURL)
    }

    private static func synchronizeDirectory(_ url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            return
        }
        _ = Darwin.fsync(descriptor)
        Darwin.close(descriptor)
    }
}

final class AudioExportStemTransaction {
    enum TransactionError: LocalizedError {
        case missingStagedOutput(URL)

        var errorDescription: String? {
            switch self {
            case let .missingStagedOutput(url):
                return "The staged stem \(url.lastPathComponent) could not be found."
            }
        }
    }

    let finalFolderURL: URL
    let stagingFolderURL: URL

    private var stagedOutputs: [(staged: URL, final: URL)] = []
    private var committedURLs: [URL] = []

    init(finalFolderURL: URL) throws {
        self.finalFolderURL = finalFolderURL.standardizedFileURL
        let parentURL = self.finalFolderURL.deletingLastPathComponent()
        stagingFolderURL = parentURL.appendingPathComponent(
            ".soundtime-stems-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingFolderURL,
            withIntermediateDirectories: true
        )
    }

    func stageURL(for finalURL: URL) -> URL {
        let stagedURL = stagingFolderURL.appendingPathComponent(finalURL.lastPathComponent)
        stagedOutputs.append((stagedURL, finalURL))
        return stagedURL
    }

    func commit() throws -> [URL] {
        try FileManager.default.createDirectory(
            at: finalFolderURL,
            withIntermediateDirectories: true
        )

        do {
            for (stagedURL, finalURL) in stagedOutputs {
                guard FileManager.default.fileExists(atPath: stagedURL.path) else {
                    throw TransactionError.missingStagedOutput(stagedURL)
                }
                try FileManager.default.moveItem(at: stagedURL, to: finalURL)
                committedURLs.append(finalURL)
            }
            try? FileManager.default.removeItem(at: stagingFolderURL)
            return committedURLs
        } catch {
            rollback()
            throw error
        }
    }

    func cancel() {
        rollback()
    }

    private func rollback() {
        for url in committedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        committedURLs.removeAll()
        try? FileManager.default.removeItem(at: stagingFolderURL)
    }
}
