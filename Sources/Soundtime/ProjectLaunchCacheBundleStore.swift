import Foundation

struct ProjectLaunchCacheGenerationPointer: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var createdAt: TimeInterval
    var projectPath: String
    var generationID: UUID
    var visualFingerprint: ProjectLaunchVisualFingerprint
    var projectID: UUID?
    var editGraphRevision: UInt64?
    var visualRevision: UInt64?
    var launchStateRevision: UInt64?
    var manifestByteCount: Int
    var firstFramePacketByteCount: Int?
    var snapshotByteCount: Int?

    init(
        projectURL: URL,
        generationID: UUID,
        visualFingerprint: ProjectLaunchVisualFingerprint,
        projectID: UUID?,
        editGraphRevision: UInt64?,
        visualRevision: UInt64?,
        launchStateRevision: UInt64?,
        manifestByteCount: Int,
        firstFramePacketByteCount: Int?,
        snapshotByteCount: Int?
    ) {
        schemaVersion = Self.currentSchemaVersion
        createdAt = Date().timeIntervalSince1970
        projectPath = projectURL.standardizedFileURL.path
        self.generationID = generationID
        self.visualFingerprint = visualFingerprint
        self.projectID = projectID
        self.editGraphRevision = editGraphRevision
        self.visualRevision = visualRevision
        self.launchStateRevision = launchStateRevision
        self.manifestByteCount = manifestByteCount
        self.firstFramePacketByteCount = firstFramePacketByteCount
        self.snapshotByteCount = snapshotByteCount
    }

    func isCompatible(with projectURL: URL) -> Bool {
        schemaVersion == Self.currentSchemaVersion &&
            projectPath == projectURL.standardizedFileURL.path
    }
}

struct ProjectLaunchCachePublishedGeneration: Sendable {
    var generationID: UUID
    var manifestByteCount: Int
    var firstFramePacketByteCount: Int?
    var snapshotByteCount: Int?
}

enum ProjectLaunchCacheBundleStore {
    static let currentPointerByteLimit = 64 * 1_024
    private static let manifestFilename = "manifest.json"
    private static let firstFramePacketFilename = "first-frame.bin"
    private static let snapshotFilename = "snapshot.bin"
    private static let currentPointerFilename = "current.json"

    @discardableResult
    static func publish(
        manifest: ProjectLaunchManifest,
        firstFramePacket: ProjectFirstFrameWaveformPacket?,
        snapshot: ProjectLaunchSnapshot?,
        for projectURL: URL
    ) throws -> ProjectLaunchCachePublishedGeneration {
        let standardizedProjectURL = projectURL.standardizedFileURL
        guard manifest.isCompatibleForFirstPaint else {
            throw CocoaError(.fileWriteUnknown)
        }

        if let firstFramePacket {
            guard
                firstFramePacket.isCompatibleForFirstPaint(with: standardizedProjectURL),
                firstFramePacket.visualFingerprint == manifest.visualFingerprint
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        if let snapshot {
            guard
                snapshot.isCompatibleForFirstPaint(with: standardizedProjectURL),
                snapshot.visualFingerprint == manifest.visualFingerprint
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let projectDirectory = projectDirectoryURL(for: standardizedProjectURL)
        let generationsDirectory = projectDirectory.appendingPathComponent("generations", isDirectory: true)
        try FileManager.default.createDirectory(at: generationsDirectory, withIntermediateDirectories: true)

        let generationID = UUID()
        let temporaryDirectory = projectDirectory.appendingPathComponent(".tmp-\(generationID.uuidString)", isDirectory: true)
        let generationDirectory = generationsDirectory.appendingPathComponent(generationID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        do {
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(
                to: temporaryDirectory.appendingPathComponent(manifestFilename),
                options: [.atomic]
            )

            let packetData: Data?
            if let firstFramePacket {
                packetData = try ProjectFirstFrameWaveformPacketBinaryCodec.encode(firstFramePacket)
                try packetData?.write(
                    to: temporaryDirectory.appendingPathComponent(firstFramePacketFilename),
                    options: [.atomic]
                )
            } else {
                packetData = nil
            }

            let snapshotData: Data?
            if let snapshot {
                snapshotData = try ProjectLaunchSnapshotBinaryCodec.encode(snapshot)
                try snapshotData?.write(
                    to: temporaryDirectory.appendingPathComponent(snapshotFilename),
                    options: [.atomic]
                )
            } else {
                snapshotData = nil
            }

            _ = try JSONDecoder().decode(ProjectLaunchManifest.self, from: manifestData)
            if let packetData {
                _ = try ProjectFirstFrameWaveformPacketBinaryCodec.decode(packetData)
            }
            if let snapshotData {
                _ = try ProjectLaunchSnapshotBinaryCodec.decode(snapshotData)
            }

            try? FileManager.default.removeItem(at: generationDirectory)
            try FileManager.default.moveItem(at: temporaryDirectory, to: generationDirectory)

            let pointer = ProjectLaunchCacheGenerationPointer(
                projectURL: standardizedProjectURL,
                generationID: generationID,
                visualFingerprint: manifest.visualFingerprint,
                projectID: manifest.projectID,
                editGraphRevision: manifest.editGraphRevision,
                visualRevision: manifest.visualRevision,
                launchStateRevision: manifest.launchStateRevision,
                manifestByteCount: manifestData.count,
                firstFramePacketByteCount: packetData?.count,
                snapshotByteCount: snapshotData?.count
            )
            let pointerData = try JSONEncoder().encode(pointer)
            try pointerData.write(to: currentPointerURL(for: standardizedProjectURL), options: [.atomic])
            pruneOldGenerations(keeping: generationID, in: generationsDirectory)

            return ProjectLaunchCachePublishedGeneration(
                generationID: generationID,
                manifestByteCount: manifestData.count,
                firstFramePacketByteCount: packetData?.count,
                snapshotByteCount: snapshotData?.count
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    static func loadManifest(for projectURL: URL) -> ProjectLaunchManifest? {
        guard let pointer = loadPointer(for: projectURL) else {
            return nil
        }
        guard pointer.manifestByteCount <= ProjectLaunchManifestStore.firstPaintSynchronousByteLimit else {
            return nil
        }
        let url = generationDirectoryURL(for: projectURL, pointer: pointer)
            .appendingPathComponent(manifestFilename)
        guard
            let data = try? Data(contentsOf: url),
            data.count == pointer.manifestByteCount,
            let manifest = try? JSONDecoder().decode(ProjectLaunchManifest.self, from: data),
            manifest.schemaVersion == ProjectLaunchManifest.currentSchemaVersion,
            manifest.projectPath == projectURL.standardizedFileURL.path,
            manifest.visualFingerprint == pointer.visualFingerprint,
            manifest.isCompatibleForFirstPaint
        else {
            return nil
        }
        return manifest
    }

    static func loadFirstFramePacketForFirstPaintIfAvailable(
        for projectURL: URL
    ) -> ProjectFirstFrameWaveformPacket? {
        guard
            let pointer = loadPointer(for: projectURL),
            let byteCount = pointer.firstFramePacketByteCount,
            byteCount > 0,
            byteCount <= ProjectFirstFrameWaveformPacketStore.firstPaintSynchronousByteLimit
        else {
            return nil
        }

        let url = generationDirectoryURL(for: projectURL, pointer: pointer)
            .appendingPathComponent(firstFramePacketFilename)
        guard
            let data = try? Data(contentsOf: url),
            data.count == byteCount,
            ProjectFirstFrameWaveformPacketBinaryCodec.hasBinaryMagic(data),
            let packet = try? ProjectFirstFrameWaveformPacketBinaryCodec.decode(data),
            packet.schemaVersion == ProjectFirstFrameWaveformPacket.currentSchemaVersion,
            packet.visualFingerprint == pointer.visualFingerprint,
            packet.isCompatibleForFirstPaint(with: projectURL)
        else {
            return nil
        }
        return packet
    }

    static func loadSnapshotForFirstPaintIfAvailable(for projectURL: URL) -> ProjectLaunchSnapshot? {
        guard
            let pointer = loadPointer(for: projectURL),
            let byteCount = pointer.snapshotByteCount,
            byteCount > 0,
            byteCount <= ProjectLaunchSnapshotStore.firstPaintSynchronousByteLimit
        else {
            return nil
        }

        let url = generationDirectoryURL(for: projectURL, pointer: pointer)
            .appendingPathComponent(snapshotFilename)
        guard
            let data = try? Data(contentsOf: url),
            data.count == byteCount,
            ProjectLaunchSnapshotBinaryCodec.hasBinaryMagic(data),
            let snapshot = try? ProjectLaunchSnapshotBinaryCodec.decode(data),
            snapshot.schemaVersion == ProjectLaunchSnapshot.currentSchemaVersion,
            snapshot.visualFingerprint == pointer.visualFingerprint,
            snapshot.isCompatibleForFirstPaint(with: projectURL)
        else {
            return nil
        }
        return snapshot.validatedForLaunch(projectURL: projectURL, validatesTrackSources: false)
    }

    static func loadSnapshot(for projectURL: URL) throws -> ProjectLaunchSnapshot {
        guard
            let pointer = loadPointer(for: projectURL),
            let byteCount = pointer.snapshotByteCount,
            byteCount > 0
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        let url = generationDirectoryURL(for: projectURL, pointer: pointer)
            .appendingPathComponent(snapshotFilename)
        let data = try Data(contentsOf: url)
        guard data.count == byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let snapshot = try ProjectLaunchSnapshotBinaryCodec.decode(data)
        guard
            snapshot.schemaVersion == ProjectLaunchSnapshot.currentSchemaVersion,
            snapshot.visualFingerprint == pointer.visualFingerprint,
            snapshot.isCompatible(with: projectURL)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot.validatedForLaunch(projectURL: projectURL)
    }

    static func remove(for projectURL: URL) {
        try? FileManager.default.removeItem(at: projectDirectoryURL(for: projectURL))
    }

    private static func loadPointer(for projectURL: URL) -> ProjectLaunchCacheGenerationPointer? {
        let standardizedProjectURL = projectURL.standardizedFileURL
        let url = currentPointerURL(for: standardizedProjectURL)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSize = (attributes[.size] as? NSNumber)?.intValue,
            fileSize > 0,
            fileSize <= currentPointerByteLimit,
            let data = try? Data(contentsOf: url),
            let pointer = try? JSONDecoder().decode(ProjectLaunchCacheGenerationPointer.self, from: data),
            pointer.isCompatible(with: standardizedProjectURL)
        else {
            return nil
        }
        return pointer
    }

    private static func pruneOldGenerations(keeping generationID: UUID, in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in urls where url.lastPathComponent != generationID.uuidString {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func generationDirectoryURL(
        for projectURL: URL,
        pointer: ProjectLaunchCacheGenerationPointer
    ) -> URL {
        projectDirectoryURL(for: projectURL)
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(pointer.generationID.uuidString, isDirectory: true)
    }

    private static func currentPointerURL(for projectURL: URL) -> URL {
        projectDirectoryURL(for: projectURL)
            .appendingPathComponent(currentPointerFilename)
    }

    private static func projectDirectoryURL(for projectURL: URL) -> URL {
        rootDirectoryURL()
            .appendingPathComponent(SoundtimeProjectStore.stableProjectKey(for: projectURL), isDirectory: true)
            .standardizedFileURL
    }

    private static func rootDirectoryURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Soundtime", isDirectory: true)
            .appendingPathComponent("LaunchGenerations", isDirectory: true)
            .standardizedFileURL
    }
}
