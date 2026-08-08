import AudioToolbox
import Darwin
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

    var isSystemEncoderAvailable: Bool {
        let formatID: AudioFormatID
        switch self {
        case .wav:
            return true
        case .m4a, .aac:
            formatID = kAudioFormatMPEG4AAC
        case .mp3:
            formatID = kAudioFormatMPEGLayer3
        }

        var requestedFormatID = formatID
        var propertySize: UInt32 = 0
        let infoStatus = withUnsafePointer(to: &requestedFormatID) { formatPointer in
            AudioFormatGetPropertyInfo(
                kAudioFormatProperty_Encoders,
                UInt32(MemoryLayout<AudioFormatID>.size),
                formatPointer,
                &propertySize
            )
        }
        guard infoStatus == noErr else {
            return false
        }
        let count = Int(propertySize) / MemoryLayout<AudioClassDescription>.stride
        guard count > 0 else {
            return false
        }
        var encoders = [AudioClassDescription](
            repeating: AudioClassDescription(),
            count: count
        )
        let propertyStatus = withUnsafePointer(to: &requestedFormatID) { formatPointer in
            AudioFormatGetProperty(
                kAudioFormatProperty_Encoders,
                UInt32(MemoryLayout<AudioFormatID>.size),
                formatPointer,
                &propertySize,
                &encoders
            )
        }
        guard propertyStatus == noErr else {
            return false
        }
        return !encoders.isEmpty
    }
}

enum AudioExportWAVEncoding: String, CaseIterable, Codable, Sendable {
    case pcm16
    case pcm24
    case float32

    var displayName: String {
        switch self {
        case .pcm16:
            return "16-bit PCM"
        case .pcm24:
            return "24-bit PCM"
        case .float32:
            return "32-bit Float"
        }
    }

    var bytesPerSample: Int {
        switch self {
        case .pcm16:
            return 2
        case .pcm24:
            return 3
        case .float32:
            return 4
        }
    }
}

enum AudioExportCompressedQuality: Int, CaseIterable, Codable, Sendable {
    case compact = 128_000
    case standard = 192_000
    case high = 256_000

    var displayName: String {
        switch self {
        case .compact:
            return "Compact (128 kbps)"
        case .standard:
            return "Standard (192 kbps)"
        case .high:
            return "High (256 kbps)"
        }
    }
}

struct AudioExportStemOptions: Sendable, Equatable {
    enum TrackInclusion: String, Sendable {
        case allTracks
        case audibleTracks
    }

    enum GainPosition: String, Sendable {
        case preFader
        case postFader
    }

    let trackInclusion: TrackInclusion
    let gainPosition: GainPosition

    static let v1Default = AudioExportStemOptions(
        trackInclusion: .allTracks,
        gainPosition: .postFader
    )
}

enum AudioExportScope: Sendable {
    case fullMixdown
    case timeRange(TimelineSelection)
    case trackRange(trackID: UUID, selection: TimelineSelection)
    case clip(trackID: UUID, clipID: AudioTimelineClipID, selection: TimelineSelection)
    case stems(includeMixdown: Bool, selection: TimelineSelection?)

    var displayName: String {
        switch self {
        case .fullMixdown:
            return "Full Mixdown"
        case .timeRange:
            return "Selected Range"
        case .trackRange:
            return "Track Range"
        case .clip:
            return "Clip"
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
        case let .clip(_, _, selection):
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
    let wavEncoding: AudioExportWAVEncoding
    let compressedQuality: AudioExportCompressedQuality
    let stemOptions: AudioExportStemOptions

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        projectName: String,
        scope: AudioExportScope,
        format: AudioExportFormat,
        destinationURL: URL,
        wavEncoding: AudioExportWAVEncoding = .pcm24,
        compressedQuality: AudioExportCompressedQuality = .standard,
        stemOptions: AudioExportStemOptions = .v1Default
    ) {
        self.id = id
        self.createdAt = createdAt
        self.projectName = projectName
        self.scope = scope
        self.format = format
        self.destinationURL = destinationURL
        self.wavEncoding = wavEncoding
        self.compressedQuality = compressedQuality
        self.stemOptions = stemOptions
    }
}

enum AudioExportStage: String, Sendable {
    case preparing
    case rendering
    case encoding
    case validating
    case committing
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
        case .validating:
            return "Validating"
        case .committing:
            return "Saving"
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
    let validations: [AudioExportOutputValidator.Validation]
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
    let validations: [AudioExportOutputValidator.Validation]
}

protocol AudioExportSampleWriter: AnyObject {
    var url: URL { get }
    func append(samplesByChannel: [[Float]], frameCount chunkFrameCount: Int) throws
    func finish() throws -> URL
    func cancel()
}

enum AudioExportTrackSource: Sendable {
    case decoded(DecodedAudioBuffer)
    case decodedSegments(DecodedAudioBuffer, [AudioEditTimeline.PlaybackSegment])
    case timeline(AudioEditTimeline)
    case file(URL, WAVFileInfo)
    case fileSegments(URL, WAVFileInfo, [AudioEditTimeline.PlaybackSegment])
    case fileTimeline(URL, WAVFileInfo, AudioFileEditTimeline)
}

struct AudioExportTrackSnapshot: Sendable {
    let id: UUID
    let logicalTrackID: UUID
    let name: String
    let volume: Float
    let pan: Float
    let isMuted: Bool
    let isSoloed: Bool
    let volumeAutomation: [TimelinePlaybackAutomationPoint]
    let panAutomation: [TimelinePlaybackAutomationPoint]
    let muteAutomation: [TimelinePlaybackAutomationPoint]
    let source: AudioExportTrackSource
    let sourceFingerprint: AudioExportSourceFingerprint?

    init(
        id: UUID,
        logicalTrackID: UUID? = nil,
        name: String,
        volume: Float,
        pan: Float = 0,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        volumeAutomation: [TimelinePlaybackAutomationPoint] = [],
        panAutomation: [TimelinePlaybackAutomationPoint] = [],
        muteAutomation: [TimelinePlaybackAutomationPoint] = [],
        source: AudioExportTrackSource
    ) {
        self.id = id
        self.logicalTrackID = logicalTrackID ?? id
        self.name = name
        self.volume = volume
        self.pan = min(max(pan, -1), 1)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.volumeAutomation = volumeAutomation
        self.panAutomation = panAutomation
        self.muteAutomation = muteAutomation
        self.source = source
        sourceFingerprint = AudioExportSourceFingerprint.capture(
            url: Self.sourceURL(for: source)
        )
    }

    var sourceURL: URL? {
        Self.sourceURL(for: source)
    }

    private static func sourceURL(for source: AudioExportTrackSource) -> URL? {
        switch source {
        case let .decoded(buffer):
            return buffer.url
        case let .decodedSegments(buffer, _):
            return buffer.url
        case let .timeline(timeline):
            return timeline.sourceAudioBuffer.url
        case let .file(url, _):
            return url
        case let .fileSegments(url, _, _):
            return url
        case let .fileTimeline(url, _, _):
            return url
        }
    }
}

struct AudioExportSourceFingerprint: Sendable, Codable, Equatable {
    let canonicalPath: String
    let fileSize: Int64
    let modificationNanoseconds: Int64
    let deviceID: UInt64
    let inode: UInt64

    static func capture(url: URL?) -> AudioExportSourceFingerprint? {
        guard let url else {
            return nil
        }
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return Darwin.lstat(path, &metadata)
        }
        guard status == 0 else {
            return nil
        }
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let modificationNanoseconds =
            Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000 +
            Int64(metadata.st_mtimespec.tv_nsec)
        return AudioExportSourceFingerprint(
            canonicalPath: canonicalURL.path,
            fileSize: Int64(metadata.st_size),
            modificationNanoseconds: modificationNanoseconds,
            deviceID: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
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
    /// Canonical clip graph revision captured by this immutable export. Zero
    /// identifies legacy/non-project smoke fixtures.
    let clipGraphRevision: UInt64

    init(
        id: UUID,
        createdAt: Date,
        request: AudioExportRequest,
        tracks: [AudioExportTrackSnapshot],
        sampleRate: Double,
        channelCount: Int,
        fullDurationFrameCount: Int,
        exportFrameRange: Range<Int>,
        leasedURLs: [URL],
        clipGraphRevision: UInt64 = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.request = request
        self.tracks = tracks
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.fullDurationFrameCount = fullDurationFrameCount
        self.exportFrameRange = exportFrameRange
        self.leasedURLs = leasedURLs
        self.clipGraphRevision = clipGraphRevision
    }

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
