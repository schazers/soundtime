import Foundation

enum TranscriptSidecarStore {
    enum SidecarError: LocalizedError {
        case invalidPath(String)

        var errorDescription: String? {
            switch self {
            case let .invalidPath(path):
                "Invalid transcript sidecar path: \(path)"
            }
        }
    }

    static func projectWithSidecarReferences(
        _ project: SoundtimeProject,
        projectURL: URL
    ) throws -> SoundtimeProject {
        var nextProject = project
        let baseDirectory = projectURL.deletingLastPathComponent()
        var tracks: [SoundtimeProject.Track] = []
        tracks.reserveCapacity(project.tracks.count)

        for sourceTrack in project.tracks {
            var track = sourceTrack
            guard let transcript = sourceTrack.transcript, !transcript.segments.isEmpty else {
                tracks.append(track)
                continue
            }

            let reference = transcript.storageReference ??
                TranscriptDocument.StorageReference.defaultSidecar(
                    transcriptID: transcript.id,
                    trackID: sourceTrack.id
                )
            let sidecarURL = try resolvedSidecarURL(reference: reference, baseDirectory: baseDirectory)
            try FileManager.default.createDirectory(
                at: sidecarURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let sidecarTranscript = transcript.withStorageReference(reference)
            let data = try sidecarEncoder.encode(sidecarTranscript)
            try data.write(to: sidecarURL, options: [.atomic])
            track.transcript = sidecarTranscript.metadataOnlySidecarReference()
            tracks.append(track)
        }

        nextProject.tracks = tracks
        return nextProject
    }

    static func projectResolvingSidecars(
        _ project: SoundtimeProject,
        projectURL: URL
    ) -> SoundtimeProject {
        var nextProject = project
        let baseDirectory = projectURL.deletingLastPathComponent()
        nextProject.tracks = project.tracks.map { sourceTrack in
            var track = sourceTrack
            guard
                let transcript = sourceTrack.transcript,
                transcript.segments.isEmpty,
                let reference = transcript.storageReference,
                let sidecarURL = try? resolvedSidecarURL(reference: reference, baseDirectory: baseDirectory),
                let data = try? Data(contentsOf: sidecarURL),
                let resolvedTranscript = try? sidecarDecoder.decode(TranscriptDocument.self, from: data)
            else {
                return track
            }

            track.transcript = resolvedTranscript
            return track
        }
        return nextProject
    }

    private static var sidecarEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var sidecarDecoder: JSONDecoder {
        JSONDecoder()
    }

    private static func resolvedSidecarURL(
        reference: TranscriptDocument.StorageReference,
        baseDirectory: URL
    ) throws -> URL {
        guard reference.kind == "project-sidecar-json" else {
            throw SidecarError.invalidPath(reference.path)
        }
        guard
            !reference.path.isEmpty,
            !reference.path.hasPrefix("/"),
            !reference.path.contains("..")
        else {
            throw SidecarError.invalidPath(reference.path)
        }

        return baseDirectory
            .appendingPathComponent(reference.path)
            .standardizedFileURL
    }
}

extension TranscriptDocument {
    func withStorageReference(_ reference: TranscriptDocument.StorageReference) -> TranscriptDocument {
        var transcript = self
        transcript.storageReference = reference
        return transcript
    }

    func metadataOnlySidecarReference() -> TranscriptDocument {
        var transcript = self
        transcript.segments = []
        return transcript
    }
}
