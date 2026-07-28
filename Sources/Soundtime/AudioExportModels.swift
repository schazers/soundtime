import Foundation

enum AudioExportFormat: String, CaseIterable, Sendable {
    case wav
    case m4a
    case aac
    case mp3

    var displayName: String {
        switch self {
        case .wav:
            return "WAV"
        case .m4a:
            return "M4A"
        case .aac:
            return "AAC"
        case .mp3:
            return "MP3"
        }
    }

    var fileExtension: String {
        rawValue
    }

    var isCompressed: Bool {
        switch self {
        case .wav:
            return false
        case .m4a, .aac, .mp3:
            return true
        }
    }

    init(destinationURL: URL) {
        self = Self(rawValue: destinationURL.pathExtension.lowercased()) ?? .wav
    }
}

enum AudioExportScope: Sendable {
    case fullMixdown
    case timeRange(TimelineSelection)
    case trackRange(trackID: UUID, selection: TimelineSelection)
    case stems(includeMixdown: Bool, selection: TimelineSelection?)

    var displayName: String {
        switch self {
        case .fullMixdown:
            return "Full Mixdown"
        case .timeRange:
            return "Selected Range"
        case .trackRange:
            return "Track Range"
        case let .stems(includeMixdown, selection):
            if includeMixdown {
                return selection == nil ? "Mixdown Plus Stems" : "Selected Mixdown Plus Stems"
            }
            return selection == nil ? "Stems" : "Selected Stems"
        }
    }

    var selection: TimelineSelection? {
        switch self {
        case .fullMixdown:
            return nil
        case let .timeRange(selection):
            return selection
        case let .trackRange(_, selection):
            return selection
        case let .stems(_, selection):
            return selection
        }
    }

    var exportsStems: Bool {
        if case .stems = self {
            return true
        }
        return false
    }
}

struct AudioExportRequest: Sendable {
    let id: UUID
    let createdAt: Date
    let projectName: String
    let scope: AudioExportScope
    let format: AudioExportFormat
    let destinationURL: URL
    let appliesPodcastMastering: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        projectName: String,
        scope: AudioExportScope,
        format: AudioExportFormat,
        destinationURL: URL,
        appliesPodcastMastering: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.projectName = projectName
        self.scope = scope
        self.format = format
        self.destinationURL = destinationURL
        self.appliesPodcastMastering = appliesPodcastMastering
    }
}

enum AudioExportStage: String, Sendable {
    case preparing
    case rendering
    case encoding
    case finishing
    case completed
    case canceled
    case failed

    var displayName: String {
        switch self {
        case .preparing:
            return "Preparing"
        case .rendering:
            return "Rendering"
        case .encoding:
            return "Encoding"
        case .finishing:
            return "Finishing"
        case .completed:
            return "Complete"
        case .canceled:
            return "Canceled"
        case .failed:
            return "Failed"
        }
    }
}

struct AudioExportProgress: Sendable {
    let jobID: UUID
    let request: AudioExportRequest
    let stage: AudioExportStage
    let fractionCompleted: Double
    let message: String
    let outputURLs: [URL]

    static func initial(request: AudioExportRequest) -> AudioExportProgress {
        AudioExportProgress(
            jobID: request.id,
            request: request,
            stage: .preparing,
            fractionCompleted: 0,
            message: "Preparing export snapshot",
            outputURLs: []
        )
    }
}

struct AudioExportResult: Sendable {
    let request: AudioExportRequest
    let outputURLs: [URL]
    let elapsedSeconds: TimeInterval
    let renderedFrameCount: Int
    let renderStats: AudioExportRenderStats
    let reportURL: URL?
}

struct AudioExportRenderStats: Sendable, Codable, Equatable {
    var renderedFrameCount: Int
    var peakMagnitude: Float
    var clippedSampleCount: Int

    static let empty = AudioExportRenderStats(
        renderedFrameCount: 0,
        peakMagnitude: 0,
        clippedSampleCount: 0
    )

    mutating func merge(_ other: AudioExportRenderStats) {
        renderedFrameCount += other.renderedFrameCount
        peakMagnitude = max(peakMagnitude, other.peakMagnitude)
        clippedSampleCount += other.clippedSampleCount
    }
}

struct AudioExportCompletedWrite: Sendable {
    let outputURLs: [URL]
    let renderStats: AudioExportRenderStats
    let reportURL: URL?
}

protocol AudioExportSampleWriter: AnyObject {
    var url: URL { get }
    func append(samplesByChannel: [[Float]], frameCount chunkFrameCount: Int) throws
    func finish() throws -> URL
    func cancel()
}

enum AudioExportTrackSource: Sendable {
    case decoded(DecodedAudioBuffer)
    case timeline(AudioEditTimeline)
    case file(URL, WAVFileInfo)
    case fileTimeline(URL, WAVFileInfo, AudioFileEditTimeline)
}

struct AudioExportTrackSnapshot: Sendable {
    let id: UUID
    let name: String
    let volume: Float
    let source: AudioExportTrackSource

    var sourceURL: URL? {
        switch source {
        case let .decoded(buffer):
            return buffer.url
        case let .timeline(timeline):
            return timeline.sourceAudioBuffer.url
        case let .file(url, _):
            return url
        case let .fileTimeline(url, _, _):
            return url
        }
    }
}

struct AudioExportSnapshot: Sendable {
    let id: UUID
    let createdAt: Date
    let request: AudioExportRequest
    let tracks: [AudioExportTrackSnapshot]
    let sampleRate: Double
    let channelCount: Int
    let fullDurationFrameCount: Int
    let exportFrameRange: Range<Int>
    let leasedURLs: [URL]

    var frameCount: Int {
        exportFrameRange.count
    }

    var duration: TimeInterval {
        guard sampleRate > 0 else {
            return 0
        }
        return Double(frameCount) / sampleRate
    }
}
