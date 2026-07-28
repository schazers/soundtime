import AVFoundation
import Foundation

enum ShippabilityFixtureBuilder {
    private static let defaultRelativeOutputPath = "Fixtures/Shippability/v1"
    private static let stableModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let sampleRate = 48_000.0
    private static let launchPreviewBinCount = SoundtimeProject.launchWaveformPreviewBinCount
    private static let sourceOverviewBinCount = 16_384
    private static let expectedNamingScheme = "st-ship-{audio|project}-NNN-{role}-{duration-or-scenario}.{ext}"
    private static let expectedSupportedImportFormatsCovered = ["wav", "aiff", "mp3", "m4a", "aac", "flac", "caf"]
    private static let expectedRecognizedUnsupportedFormatsCovered = ["ogg"]

    private enum BuilderError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    private enum FixtureImportExpectation: String, Codable {
        case importable
        case recognizedUnsupported
    }

    private struct ExpectedAudioFixture {
        var id: String
        var role: String
        var path: String
        var format: AudioAssetFormat
        var durationSeconds: Double
        var projectReady: Bool
        var importExpectation: FixtureImportExpectation
    }

    private struct ExpectedProjectFixture {
        var id: String
        var role: String
        var path: String
        var trackCount: Int
        var durationSeconds: Double
    }

    private enum FixtureProfile: String {
        case quick
        case full

        var includesTrueLongFixtures: Bool {
            self == .full
        }

        var description: String {
            switch self {
            case .quick:
                return "quick"
            case .full:
                return "full"
            }
        }
    }

    private struct GeneratedAudio {
        var id: String
        var role: String
        var url: URL
        var buffer: DecodedAudioBuffer?
        var fileInfo: WAVFileInfo?
        var sourceOverview: WaveformOverview?
        var format: AudioAssetFormat
        var duration: TimeInterval
        var projectReady: Bool
        var importExpectation: FixtureImportExpectation
    }

    private struct GeneratedProject {
        var id: String
        var role: String
        var url: URL
        var trackCount: Int
        var duration: TimeInterval
    }

    private struct FixtureManifest: Codable {
        struct Entry: Codable {
            var id: String
            var role: String
            var path: String
            var format: String?
            var durationSeconds: Double?
            var trackCount: Int?
            var projectReady: Bool?
            var importExpectation: FixtureImportExpectation?
        }

        var schemaVersion: Int
        var fixtureVersion: String
        var profile: String
        var generatedBy: String
        var namingScheme: String
        var supportedImportFormatsCovered: [String]
        var recognizedUnsupportedFormatsCovered: [String]
        var audio: [Entry]
        var projects: [Entry]
    }

    private static let expectedAudioFixtures: [ExpectedAudioFixture] = [
        ExpectedAudioFixture(
            id: "st-ship-audio-001",
            role: "Short spoken WAV for tiny launch/edit smoke",
            path: "audio/st-ship-audio-001-short-voice-12s.wav",
            format: .wav,
            durationSeconds: 12,
            projectReady: true,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-002",
            role: "Long voice-like WAV for startup/playback timing",
            path: "audio/st-ship-audio-002-long-podcast-180s.wav",
            format: .wav,
            durationSeconds: 180,
            projectReady: true,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-003",
            role: "Stereo music-bed WAV for zoom/render stress",
            path: "audio/st-ship-audio-003-music-bed-90s.wav",
            format: .wav,
            durationSeconds: 90,
            projectReady: true,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-004",
            role: "Transient-heavy WAV for playhead glow and particle alignment",
            path: "audio/st-ship-audio-004-transient-clicks-60s.wav",
            format: .wav,
            durationSeconds: 60,
            projectReady: true,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-005",
            role: "Editable WAV proxy matching compressed import fixtures",
            path: "audio/st-ship-audio-005-import-podcast-editable-proxy-45s.wav",
            format: .wav,
            durationSeconds: 45,
            projectReady: true,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-006",
            role: "Compressed MP3 import fixture",
            path: "audio/st-ship-audio-006-import-podcast-45s.mp3",
            format: .mp3,
            durationSeconds: 45,
            projectReady: false,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-007",
            role: "AIFF import fixture",
            path: "audio/st-ship-audio-007-import-voice-30s.aiff",
            format: .aiff,
            durationSeconds: 30,
            projectReady: false,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-008",
            role: "M4A/AAC import fixture",
            path: "audio/st-ship-audio-008-import-music-30s.m4a",
            format: .mpeg4Audio,
            durationSeconds: 30,
            projectReady: false,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-009",
            role: "Standalone AAC import fixture",
            path: "audio/st-ship-audio-009-import-voice-30s.aac",
            format: .aac,
            durationSeconds: 30,
            projectReady: false,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-010",
            role: "FLAC import fixture",
            path: "audio/st-ship-audio-010-import-music-30s.flac",
            format: .flac,
            durationSeconds: 30,
            projectReady: false,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-011",
            role: "CAF import fixture",
            path: "audio/st-ship-audio-011-import-clicks-20s.caf",
            format: .caf,
            durationSeconds: 20,
            projectReady: false,
            importExpectation: .importable
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-012",
            role: "Recognized unsupported Ogg fixture for unsupported-file UI",
            path: "audio/st-ship-audio-012-unsupported-ogg-placeholder.ogg",
            format: .ogg,
            durationSeconds: 0,
            projectReady: false,
            importExpectation: .recognizedUnsupported
        ),
        ExpectedAudioFixture(
            id: "st-ship-audio-013",
            role: "True long podcast-scale WAV for release startup and playback confidence",
            path: "audio/st-ship-audio-013-true-long-podcast-30m.wav",
            format: .wav,
            durationSeconds: 1_800,
            projectReady: true,
            importExpectation: .importable
        ),
    ]

    private static func expectedAudioFixtures(for profile: FixtureProfile) -> [ExpectedAudioFixture] {
        expectedAudioFixtures.filter { expected in
            profile.includesTrueLongFixtures || expected.id != "st-ship-audio-013"
        }
    }

    private static let expectedProjectFixtures: [ExpectedProjectFixture] = [
        ExpectedProjectFixture(
            id: "st-ship-project-001",
            role: "One short WAV track with launch preview",
            path: "projects/st-ship-project-001-short-wav-launch.soundtime",
            trackCount: 1,
            durationSeconds: 12
        ),
        ExpectedProjectFixture(
            id: "st-ship-project-002",
            role: "One long WAV track with compact first-frame preview",
            path: "projects/st-ship-project-002-long-wav-startup.soundtime",
            trackCount: 1,
            durationSeconds: 180
        ),
        ExpectedProjectFixture(
            id: "st-ship-project-003",
            role: "Compressed MP3 source represented by editable WAV proxy",
            path: "projects/st-ship-project-003-mp3-import-proxy.soundtime",
            trackCount: 1,
            durationSeconds: 45
        ),
        ExpectedProjectFixture(
            id: "st-ship-project-004",
            role: "Three-track mixed session with mute/solo state and shared edit group",
            path: "projects/st-ship-project-004-three-track-session.soundtime",
            trackCount: 3,
            durationSeconds: 180
        ),
        ExpectedProjectFixture(
            id: "st-ship-project-005",
            role: "Edited track fixture with non-trivial file timeline",
            path: "projects/st-ship-project-005-edited-delete-paste.soundtime",
            trackCount: 1,
            durationSeconds: 85.35
        ),
        ExpectedProjectFixture(
            id: "st-ship-project-006",
            role: "Podcast track with deterministic transcript document",
            path: "projects/st-ship-project-006-transcribed-podcast.soundtime",
            trackCount: 1,
            durationSeconds: 180
        ),
        ExpectedProjectFixture(
            id: "st-ship-project-007",
            role: "100 tracks sharing one compact source for layout/render stress",
            path: "projects/st-ship-project-007-stress-100-tracks.soundtime",
            trackCount: 100,
            durationSeconds: 12
        ),
        ExpectedProjectFixture(
            id: "st-ship-project-008",
            role: "True 30-minute WAV project for full release startup coverage",
            path: "projects/st-ship-project-008-true-long-wav-release.soundtime",
            trackCount: 1,
            durationSeconds: 1_800
        ),
    ]

    private static func expectedProjectFixtures(for profile: FixtureProfile) -> [ExpectedProjectFixture] {
        expectedProjectFixtures.filter { expected in
            profile.includesTrueLongFixtures || expected.id != "st-ship-project-008"
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let rootDirectory = outputDirectory(
            from: arguments,
            primaryFlag: "--build-shippability-fixtures"
        )
        let profile = fixtureProfile(from: arguments)
        let result = try buildFixtures(rootDirectory: rootDirectory, profile: profile)
        print("Soundtime shippability fixtures generated")
        print("root: \(rootDirectory.path)")
        print("profile: \(profile.description)")
        print("audio files: \(result.audio.count)")
        print("projects: \(result.projects.count)")
        print("manifest: \(rootDirectory.appendingPathComponent("fixtures-manifest.json").path)")
    }

    static func verifyFromCommandLine(arguments: [String]) throws {
        let rootDirectory = outputDirectory(
            from: arguments,
            primaryFlag: "--verify-shippability-fixtures"
        )
        let profile = fixtureProfile(from: arguments)
        try verifyExistingFixtures(rootDirectory: rootDirectory, profile: profile)
        print("Soundtime shippability fixtures verified")
        print("root: \(rootDirectory.path)")
        print("profile: \(profile.description)")
        print("audio files: \(expectedAudioFixtures(for: profile).count)")
        print("projects: \(expectedProjectFixtures(for: profile).count)")
    }

    private static func fixtureProfile(from arguments: [String]) -> FixtureProfile {
        guard let profileIndex = arguments.firstIndex(of: "--fixture-profile"),
              arguments.indices.contains(profileIndex + 1),
              let profile = FixtureProfile(rawValue: arguments[profileIndex + 1])
        else {
            return .full
        }
        return profile
    }

    private static func outputDirectory(
        from arguments: [String],
        primaryFlag: String
    ) -> URL {
        if
            let explicitIndex = arguments.firstIndex(of: "--fixtures-output"),
            arguments.indices.contains(explicitIndex + 1)
        {
            return URL(fileURLWithPath: arguments[explicitIndex + 1]).standardizedFileURL
        }

        if
            let flagIndex = arguments.firstIndex(of: primaryFlag),
            arguments.indices.contains(flagIndex + 1),
            !arguments[flagIndex + 1].hasPrefix("--")
        {
            return URL(fileURLWithPath: arguments[flagIndex + 1]).standardizedFileURL
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(defaultRelativeOutputPath, isDirectory: true)
            .standardizedFileURL
    }

    @discardableResult
    private static func buildFixtures(rootDirectory: URL, profile: FixtureProfile) throws -> (
        audio: [GeneratedAudio],
        projects: [GeneratedProject]
    ) {
        let audioDirectory = rootDirectory.appendingPathComponent("audio", isDirectory: true)
        let projectDirectory = rootDirectory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.removeFixtureItemIfPresent(at: rootDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        var audio: [String: GeneratedAudio] = [:]
        audio["shortVoice"] = try writeWAVFixture(
            id: "st-ship-audio-001",
            slug: "short-voice",
            durationLabel: "12s",
            role: "Short spoken WAV for tiny launch/edit smoke",
            duration: 12,
            channelCount: 1,
            directory: audioDirectory,
            generator: makeVoiceSample
        )
        audio["longPodcast"] = try writeWAVFixture(
            id: "st-ship-audio-002",
            slug: "long-podcast",
            durationLabel: "180s",
            role: "Long voice-like WAV for startup/playback timing",
            duration: 180,
            channelCount: 1,
            directory: audioDirectory,
            generator: makePodcastSample
        )
        if profile.includesTrueLongFixtures {
            audio["trueLongPodcast"] = try writeStreamingWAVFixture(
                id: "st-ship-audio-013",
                slug: "true-long-podcast",
                durationLabel: "30m",
                role: "True long podcast-scale WAV for release startup and playback confidence",
                duration: 1_800,
                sampleRate: 24_000,
                channelCount: 1,
                directory: audioDirectory,
                generator: makePodcastSample
            )
        }
        audio["musicBed"] = try writeWAVFixture(
            id: "st-ship-audio-003",
            slug: "music-bed",
            durationLabel: "90s",
            role: "Stereo music-bed WAV for zoom/render stress",
            duration: 90,
            channelCount: 2,
            directory: audioDirectory,
            generator: makeMusicSample
        )
        audio["transients"] = try writeWAVFixture(
            id: "st-ship-audio-004",
            slug: "transient-clicks",
            durationLabel: "60s",
            role: "Transient-heavy WAV for playhead glow and particle alignment",
            duration: 60,
            channelCount: 1,
            directory: audioDirectory,
            generator: makeTransientSample
        )
        audio["importProxy"] = try writeWAVFixture(
            id: "st-ship-audio-005",
            slug: "import-podcast-editable-proxy",
            durationLabel: "45s",
            role: "Editable WAV proxy matching compressed import fixtures",
            duration: 45,
            channelCount: 2,
            directory: audioDirectory,
            generator: makeVoiceSample
        )

        let importBuffer = try requireValue(audio["importProxy"]?.buffer, "missing import proxy buffer")
        let mp3URL = audioDirectory.appendingPathComponent("st-ship-audio-006-import-podcast-45s.mp3")
        try writeCompressedFixture(importBuffer, to: mp3URL, fallbackSourceWAV: audio["importProxy"]?.url)
        audio["mp3"] = try inspectNativeFixture(
            id: "st-ship-audio-006",
            role: "Compressed MP3 import fixture",
            url: mp3URL,
            projectReady: false
        )

        let aiffBuffer = makeBuffer(
            url: audioDirectory.appendingPathComponent("st-ship-audio-007-import-voice-30s.aiff"),
            duration: 30,
            channelCount: 1,
            generator: makeVoiceSample
        )
        let aiffURL = aiffBuffer.url
        try writeNativeAudioFixture(aiffBuffer, to: aiffURL)
        try setStableModificationDate(at: aiffURL, offset: 7)
        audio["aiff"] = try inspectNativeFixture(
            id: "st-ship-audio-007",
            role: "AIFF import fixture",
            url: aiffURL,
            projectReady: false
        )

        let m4aURL = audioDirectory.appendingPathComponent("st-ship-audio-008-import-music-30s.m4a")
        let m4aBuffer = makeBuffer(
            url: m4aURL,
            duration: 30,
            channelCount: 2,
            generator: makeMusicSample
        )
        try writeCompressedFixture(m4aBuffer, to: m4aURL, fallbackSourceWAV: nil)
        audio["m4a"] = try inspectNativeFixture(
            id: "st-ship-audio-008",
            role: "M4A/AAC import fixture",
            url: m4aURL,
            projectReady: false
        )

        let aacURL = audioDirectory.appendingPathComponent("st-ship-audio-009-import-voice-30s.aac")
        let aacBuffer = makeBuffer(
            url: aacURL,
            duration: 30,
            channelCount: 1,
            generator: makeVoiceSample
        )
        try writeCompressedFixture(aacBuffer, to: aacURL, fallbackSourceWAV: nil)
        audio["aac"] = try inspectNativeFixture(
            id: "st-ship-audio-009",
            role: "Standalone AAC import fixture",
            url: aacURL,
            projectReady: false
        )

        let flacURL = audioDirectory.appendingPathComponent("st-ship-audio-010-import-music-30s.flac")
        let flacBuffer = makeBuffer(
            url: flacURL,
            duration: 30,
            channelCount: 2,
            generator: makeMusicSample
        )
        try writeCompressedFixture(flacBuffer, to: flacURL, fallbackSourceWAV: nil)
        audio["flac"] = try inspectNativeFixture(
            id: "st-ship-audio-010",
            role: "FLAC import fixture",
            url: flacURL,
            projectReady: false
        )

        let cafURL = audioDirectory.appendingPathComponent("st-ship-audio-011-import-clicks-20s.caf")
        let cafBuffer = makeBuffer(
            url: cafURL,
            duration: 20,
            channelCount: 1,
            generator: makeTransientSample
        )
        try writeNativeAudioFixture(cafBuffer, to: cafURL)
        try setStableModificationDate(at: cafURL, offset: 11)
        audio["caf"] = try inspectNativeFixture(
            id: "st-ship-audio-011",
            role: "CAF import fixture",
            url: cafURL,
            projectReady: false
        )

        audio["unsupportedOgg"] = try writeUnsupportedFixture(
            id: "st-ship-audio-012",
            role: "Recognized unsupported Ogg fixture for unsupported-file UI",
            url: audioDirectory.appendingPathComponent("st-ship-audio-012-unsupported-ogg-placeholder.ogg"),
            format: .ogg
        )

        let projects = try writeProjects(
            projectDirectory: projectDirectory,
            audio: audio,
            profile: profile
        )
        try writeManifest(
            rootDirectory: rootDirectory,
            profile: profile,
            audio: audio.values.sorted { $0.id < $1.id },
            projects: projects
        )
        try writeReadme(rootDirectory: rootDirectory)
        try verifyExistingFixtures(rootDirectory: rootDirectory, profile: profile)
        return (Array(audio.values), projects)
    }

    private static func writeWAVFixture(
        id: String,
        slug: String,
        durationLabel: String,
        role: String,
        duration: TimeInterval,
        channelCount: Int,
        directory: URL,
        generator: (Double, Int, TimeInterval, inout SeededNoise) -> Float
    ) throws -> GeneratedAudio {
        let url = directory.appendingPathComponent("\(id)-\(slug)-\(durationLabel).wav")
        let buffer = makeBuffer(
            url: url,
            duration: duration,
            channelCount: channelCount,
            generator: generator
        )
        try WAVFileWriter.write(buffer, to: url)
        let stableOffset = Int(id.suffix(3)) ?? 0
        try setStableModificationDate(at: url, offset: stableOffset)
        let fileInfo = try WAVAudioDecoder.inspect(url: url)
        let overview = WaveformOverviewBuilder.build(
            from: buffer,
            targetBinCount: min(sourceOverviewBinCount, max(fileInfo.frameCount, 1))
        )
        return GeneratedAudio(
            id: id,
            role: role,
            url: url,
            buffer: buffer,
            fileInfo: fileInfo,
            sourceOverview: overview,
            format: .wav,
            duration: duration,
            projectReady: true,
            importExpectation: .importable
        )
    }

    private static func writeStreamingWAVFixture(
        id: String,
        slug: String,
        durationLabel: String,
        role: String,
        duration: TimeInterval,
        sampleRate fixtureSampleRate: Double,
        channelCount: Int,
        directory: URL,
        generator: (Double, Int, TimeInterval, inout SeededNoise) -> Float
    ) throws -> GeneratedAudio {
        let url = directory.appendingPathComponent("\(id)-\(slug)-\(durationLabel).wav")
        let frameCount = max(Int((duration * fixtureSampleRate).rounded()), 1)
        let binCount = min(sourceOverviewBinCount, frameCount)
        var bins: [WaveformOverview.Bin] = []
        bins.reserveCapacity(binCount)

        let writer = try StreamingWAVTakeWriter(url: url)
        var noise = SeededNoise(seed: UInt64(abs(url.path.hashValue)) | 1)
        var accumulator = WaveformBinAccumulator()
        var currentBinIndex = 0
        var frameIndex = 0
        let framesPerChunk = 8_192

        while frameIndex < frameCount {
            let endFrame = min(frameIndex + framesPerChunk, frameCount)
            var samplesByChannel = Array(repeating: [Float](), count: channelCount)
            for channelIndex in samplesByChannel.indices {
                samplesByChannel[channelIndex].reserveCapacity(endFrame - frameIndex)
            }

            for frame in frameIndex..<endFrame {
                let time = Double(frame) / fixtureSampleRate
                let binIndex = min(frame * binCount / frameCount, binCount - 1)
                while currentBinIndex < binIndex {
                    bins.append(accumulator.makeBin())
                    accumulator = WaveformBinAccumulator()
                    currentBinIndex += 1
                }

                var mixedSample: Float = 0
                for channel in 0..<channelCount {
                    let sample = generator(time, channel, duration, &noise)
                    samplesByChannel[channel].append(sample)
                    mixedSample += sample
                }
                accumulator.addSample(mixedSample / Float(max(channelCount, 1)))
            }

            writer.append(AudioRecordingChunk(
                samplesByChannel: samplesByChannel,
                sampleRate: fixtureSampleRate,
                channelCount: channelCount,
                frameCount: endFrame - frameIndex,
                hostTimestamp: 0
            ))
            frameIndex = endFrame
        }

        while currentBinIndex < binCount {
            bins.append(accumulator.makeBin())
            accumulator = WaveformBinAccumulator()
            currentBinIndex += 1
        }

        let recordedTake = try writer.finish()
        try setStableModificationDate(at: recordedTake.url, offset: Int(id.suffix(3)) ?? 0)
        let fileInfo = try WAVAudioDecoder.inspect(url: recordedTake.url)
        return GeneratedAudio(
            id: id,
            role: role,
            url: recordedTake.url,
            buffer: nil,
            fileInfo: fileInfo,
            sourceOverview: WaveformOverview(duration: fileInfo.duration, bins: bins),
            format: .wav,
            duration: fileInfo.duration,
            projectReady: true,
            importExpectation: .importable
        )
    }

    private static func inspectNativeFixture(
        id: String,
        role: String,
        url: URL,
        projectReady: Bool
    ) throws -> GeneratedAudio {
        let info = try AudioAssetImporter.inspectSynchronously(url: url)
        return GeneratedAudio(
            id: id,
            role: role,
            url: url,
            buffer: nil,
            fileInfo: nil,
            sourceOverview: nil,
            format: info.format,
            duration: info.duration ?? 0,
            projectReady: projectReady,
            importExpectation: .importable
        )
    }

    private static func writeUnsupportedFixture(
        id: String,
        role: String,
        url: URL,
        format: AudioAssetFormat
    ) throws -> GeneratedAudio {
        try Data("OggS-Soundtime unsupported fixture placeholder\n".utf8)
            .write(to: url, options: [.atomic])
        try setStableModificationDate(at: url, offset: Int(id.suffix(3)) ?? 0)
        return GeneratedAudio(
            id: id,
            role: role,
            url: url,
            buffer: nil,
            fileInfo: nil,
            sourceOverview: nil,
            format: format,
            duration: 0,
            projectReady: false,
            importExpectation: .recognizedUnsupported
        )
    }

    private static func writeProjects(
        projectDirectory: URL,
        audio: [String: GeneratedAudio],
        profile: FixtureProfile
    ) throws -> [GeneratedProject] {
        let shortVoice = try requireValue(audio["shortVoice"], "missing short voice fixture")
        let longPodcast = try requireValue(audio["longPodcast"], "missing long podcast fixture")
        let musicBed = try requireValue(audio["musicBed"], "missing music bed fixture")
        let transients = try requireValue(audio["transients"], "missing transient fixture")
        let importProxy = try requireValue(audio["importProxy"], "missing import proxy fixture")
        let mp3 = try requireValue(audio["mp3"], "missing mp3 fixture")

        var projects: [GeneratedProject] = []
        projects.append(try writeProject(
            id: "st-ship-project-001",
            slug: "short-wav-launch",
            role: "One short WAV track with launch preview",
            directory: projectDirectory,
            project: project(
                id: uuid(1),
                tracks: [
                    track(
                        id: uuid(101),
                        groupID: uuid(900),
                        name: "Short Voice",
                        audio: shortVoice,
                        volume: 1,
                        isMuted: false
                    ),
                ],
                viewport: .init(startProgress: 0, durationProgress: 1)
            )
        ))
        projects.append(try writeProject(
            id: "st-ship-project-002",
            slug: "long-wav-startup",
            role: "One long WAV track with compact first-frame preview",
            directory: projectDirectory,
            project: project(
                id: uuid(2),
                tracks: [
                    track(
                        id: uuid(102),
                        groupID: uuid(901),
                        name: "Long Podcast",
                        audio: longPodcast,
                        volume: 0.92,
                        isMuted: false
                    ),
                ],
                viewport: .init(startProgress: 0.12, durationProgress: 0.18)
            )
        ))
        projects.append(try writeProject(
            id: "st-ship-project-003",
            slug: "mp3-import-proxy",
            role: "Compressed MP3 source represented by editable WAV proxy",
            directory: projectDirectory,
            project: project(
                id: uuid(3),
                tracks: [
                    track(
                        id: uuid(103),
                        groupID: uuid(902),
                        name: "Imported MP3 Podcast",
                        audio: importProxy,
                        volume: 1,
                        isMuted: false,
                        editableOriginalURL: mp3.url,
                        formatOrigin: .mp3
                    ),
                ],
                viewport: .init(startProgress: 0, durationProgress: 0.45)
            )
        ))
        projects.append(try writeProject(
            id: "st-ship-project-004",
            slug: "three-track-session",
            role: "Three-track mixed session with mute/solo state and shared edit group",
            directory: projectDirectory,
            project: project(
                id: uuid(4),
                tracks: [
                    track(
                        id: uuid(104),
                        groupID: uuid(903),
                        name: "Narration Bed",
                        audio: longPodcast,
                        volume: 0.7,
                        isMuted: true
                    ),
                    track(
                        id: uuid(105),
                        groupID: uuid(903),
                        name: "Music Bed",
                        audio: musicBed,
                        volume: 0.42,
                        isMuted: false
                    ),
                    track(
                        id: uuid(106),
                        groupID: uuid(903),
                        name: "Transient Markers",
                        audio: transients,
                        volume: 0.65,
                        isMuted: false,
                        isSoloed: true
                    ),
                ],
                viewport: .init(startProgress: 0.02, durationProgress: 0.16)
            )
        ))

        let editedTimeline = try editedDeletePasteTimeline(for: musicBed)
        projects.append(try writeProject(
            id: "st-ship-project-005",
            slug: "edited-delete-paste",
            role: "Edited track fixture with non-trivial file timeline",
            directory: projectDirectory,
            project: project(
                id: uuid(5),
                tracks: [
                    track(
                        id: uuid(107),
                        groupID: uuid(904),
                        name: "Edited Music",
                        audio: musicBed,
                        volume: 0.82,
                        isMuted: false,
                        timeline: editedTimeline
                    ),
                ],
                viewport: .init(startProgress: 0.08, durationProgress: 0.12)
            )
        ))

        projects.append(try writeProject(
            id: "st-ship-project-006",
            slug: "transcribed-podcast",
            role: "Podcast track with deterministic transcript document",
            directory: projectDirectory,
            project: project(
                id: uuid(6),
                tracks: [
                    track(
                        id: uuid(108),
                        groupID: uuid(905),
                        name: "Transcript Voice",
                        audio: longPodcast,
                        volume: 1,
                        isMuted: false,
                        transcript: transcript(trackID: uuid(108), duration: longPodcast.duration)
                    ),
                ],
                viewport: .init(startProgress: 0.03, durationProgress: 0.09),
                transcriptDisplayMode: .waveformOverlay
            )
        ))

        let stressTracks = try makeStressTracks(audio: shortVoice)
        projects.append(try writeProject(
            id: "st-ship-project-007",
            slug: "stress-100-tracks",
            role: "100 tracks sharing one compact source for layout/render stress",
            directory: projectDirectory,
            project: project(
                id: uuid(7),
                tracks: stressTracks,
                viewport: .init(startProgress: 0, durationProgress: 1)
            )
        ))
        if profile.includesTrueLongFixtures {
            let trueLongPodcast = try requireValue(audio["trueLongPodcast"], "missing true long podcast fixture")
            projects.append(try writeProject(
                id: "st-ship-project-008",
                slug: "true-long-wav-release",
                role: "True 30-minute WAV project for full release startup coverage",
                directory: projectDirectory,
                project: project(
                    id: uuid(8),
                    tracks: [
                        track(
                            id: uuid(109),
                            groupID: uuid(906),
                            name: "Thirty Minute Podcast",
                            audio: trueLongPodcast,
                            volume: 0.95,
                            isMuted: false
                        ),
                    ],
                    viewport: .init(startProgress: 0.36, durationProgress: 0.035)
                )
            ))
        }

        return projects
    }

    private static func writeProject(
        id: String,
        slug: String,
        role: String,
        directory: URL,
        project: SoundtimeProject
    ) throws -> GeneratedProject {
        let url = directory.appendingPathComponent("\(id)-\(slug).soundtime")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: url, options: [.atomic])
        try setStableModificationDate(at: url, offset: Int(id.suffix(3)) ?? 0)
        return GeneratedProject(
            id: id,
            role: role,
            url: url,
            trackCount: project.tracks.count,
            duration: project.tracks
                .compactMap { trackDuration($0) }
                .max() ?? 0
        )
    }

    private static func project(
        id: UUID,
        tracks: [SoundtimeProject.Track],
        viewport: SoundtimeProject.TimelineViewport,
        transcriptDisplayMode: TranscriptTimelineDisplayMode? = nil
    ) -> SoundtimeProject {
        SoundtimeProject(
            projectID: id,
            editGraphRevision: 1,
            visualRevision: 1,
            launchStateRevision: 1,
            tracks: tracks,
            windowLayout: .init(x: 80, y: 80, width: 1_920, height: 1_080),
            masterVolume: 0.92,
            timelineViewport: viewport,
            transcriptDisplayMode: transcriptDisplayMode
        )
    }

    private static func track(
        id: UUID,
        groupID: UUID,
        name: String,
        audio: GeneratedAudio,
        volume: Float,
        isMuted: Bool,
        isSoloed: Bool = false,
        timeline explicitTimeline: AudioFileEditTimeline? = nil,
        editableOriginalURL: URL? = nil,
        formatOrigin: AudioAssetFormat = .wav,
        transcript: TranscriptDocument? = nil
    ) -> SoundtimeProject.Track {
        track(
            id: id,
            groupID: groupID,
            name: name,
            audio: audio,
            volume: volume,
            isMuted: isMuted,
            isSoloed: isSoloed,
            timeline: explicitTimeline,
            editableOriginalURL: editableOriginalURL,
            formatOrigin: formatOrigin,
            transcript: transcript,
            previewBinCount: launchPreviewBinCount
        )
    }

    private static func track(
        id: UUID,
        groupID: UUID,
        name: String,
        audio: GeneratedAudio,
        volume: Float,
        isMuted: Bool,
        isSoloed: Bool = false,
        timeline explicitTimeline: AudioFileEditTimeline? = nil,
        editableOriginalURL: URL? = nil,
        formatOrigin: AudioAssetFormat = .wav,
        transcript: TranscriptDocument? = nil,
        previewBinCount: Int
    ) -> SoundtimeProject.Track {
        guard
            let fileInfo = audio.fileInfo,
            let sourceOverview = audio.sourceOverview
        else {
            preconditionFailure("Project track \(name) requires an editable WAV audio fixture.")
        }

        let timeline = explicitTimeline ?? AudioFileEditTimeline(fileInfo: fileInfo)
        let displayOverview = timeline.hasEdits ?
            timeline.waveformOverview(from: sourceOverview) :
            sourceOverview
        let editableSource = EditableAudioSource(
            originalURL: editableOriginalURL ?? audio.url,
            editableURL: audio.url,
            formatOrigin: formatOrigin,
            fileInfo: fileInfo,
            ownsEditableFile: false
        )

        return SoundtimeProject.Track(
            id: id,
            editGroupID: groupID,
            name: name,
            filePath: audio.url.standardizedFileURL.path,
            volume: volume,
            isMuted: isMuted,
            isSoloed: isSoloed,
            editTimeline: timeline.persistentState,
            editableSource: SoundtimeProject.Track.EditableSource(editableSource),
            waveformPreview: SoundtimeProject.WaveformPreview(
                sourceOverview: sourceOverview,
                displayOverview: displayOverview,
                fileInfo: fileInfo,
                maximumBinCount: previewBinCount
            ),
            ownsSourceFile: false,
            transcript: transcript
        )
    }

    private static func makeStressTracks(audio: GeneratedAudio) throws -> [SoundtimeProject.Track] {
        let groupBase = 9_100
        return (0..<100).map { index in
            track(
                id: uuid(1_000 + index),
                groupID: uuid(groupBase + index / 10),
                name: String(format: "Stress Track %03d", index + 1),
                audio: audio,
                volume: Float(0.35 + Double(index % 8) * 0.045),
                isMuted: index >= 32,
                isSoloed: false,
                previewBinCount: 256
            )
        }
    }

    private static func editedDeletePasteTimeline(for audio: GeneratedAudio) throws -> AudioFileEditTimeline {
        let fileInfo = try requireValue(audio.fileInfo, "edited fixture missing WAV file info")
        var timeline = AudioFileEditTimeline(fileInfo: fileInfo)
        _ = timeline.delete(TimelineSelection(startProgress: 0.16, endProgress: 0.22))
        _ = timeline.insertSilence(
            frameCount: max(Int(fileInfo.sampleRate * 0.75), 1),
            atProgress: 0.48
        )
        _ = timeline.split(atProgress: 0.34)
        _ = timeline.split(atProgress: 0.78)
        _ = timeline.applyFade(.fadeIn, to: TimelineSelection(startProgress: 0.62, endProgress: 0.74))
        return timeline
    }

    private static func trackDuration(_ track: SoundtimeProject.Track) -> TimeInterval? {
        if
            let state = track.editTimeline,
            let timeline = AudioFileEditTimeline(persistentState: state)
        {
            return timeline.duration
        }
        return track.waveformPreview?.displayOverview.duration
    }

    private static func transcript(trackID: UUID, duration: TimeInterval) -> TranscriptDocument {
        let phrases: [[String]] = [
            ["Soundtime", "should", "open", "the", "project", "immediately"],
            ["The", "waveform", "preview", "must", "already", "be", "visible"],
            ["Playback", "selection", "delete", "paste", "and", "transcription", "stay", "smooth"],
            ["This", "fixture", "protects", "word", "timing", "and", "timeline", "alignment"],
        ]
        var segments: [TranscriptSegment] = []
        var currentTime: TimeInterval = 0.8
        var wordCounter = 0
        var segmentCounter = 0

        while currentTime < duration - 1 {
            let words = phrases[segmentCounter % phrases.count]
            let segmentStart = currentTime
            var transcriptWords: [TranscriptWord] = []
            for word in words {
                let wordStart = currentTime
                let wordEnd = min(wordStart + 0.34, duration)
                transcriptWords.append(TranscriptWord(
                    id: uuid(20_000 + wordCounter),
                    text: word.lowercased(),
                    rawText: word.lowercased(),
                    punctuatedText: word,
                    startTime: wordStart,
                    endTime: wordEnd,
                    confidence: 0.94,
                    speakerID: segmentCounter.isMultiple(of: 2) ? "speaker-1" : "speaker-2",
                    speakerConfidence: 0.91,
                    channelIndex: 0
                ))
                wordCounter += 1
                currentTime += 0.42
            }
            let segmentEnd = min(currentTime - 0.08, duration)
            segments.append(TranscriptSegment(
                id: uuid(30_000 + segmentCounter),
                speakerID: segmentCounter.isMultiple(of: 2) ? "speaker-1" : "speaker-2",
                speakerLabel: segmentCounter.isMultiple(of: 2) ? "Speaker 1" : "Speaker 2",
                startTime: segmentStart,
                endTime: segmentEnd,
                text: words.joined(separator: " "),
                words: transcriptWords,
                confidence: 0.93,
                speakerConfidence: 0.91,
                channelIndex: 0
            ))
            segmentCounter += 1
            currentTime += 1.2
        }

        return TranscriptDocument(
            id: uuid(40_000),
            sourceKind: .track,
            trackID: trackID,
            sourceRevision: 0,
            sourceDuration: duration,
            sourceFingerprint: "st-ship-transcript-\(trackID.uuidString)",
            languageCode: "en-US",
            providerIdentifier: "fixture",
            providerDisplayName: "Soundtime Fixture",
            providerRequestID: "st-ship-fixture-transcript",
            providerModelName: "deterministic-fixture-v1",
            createdAt: stableModificationDate,
            validity: .valid,
            segments: segments
        )
    }

    private static func makeBuffer(
        url: URL,
        duration: TimeInterval,
        channelCount: Int,
        generator: (Double, Int, TimeInterval, inout SeededNoise) -> Float
    ) -> DecodedAudioBuffer {
        let frameCount = max(Int((duration * sampleRate).rounded()), 1)
        var channels = Array(
            repeating: [Float](repeating: 0, count: frameCount),
            count: channelCount
        )
        var noise = SeededNoise(seed: UInt64(abs(url.path.hashValue)) | 1)
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            for channel in 0..<channelCount {
                channels[channel][frame] = generator(time, channel, duration, &noise)
            }
        }

        return DecodedAudioBuffer(
            url: url,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            samplesByChannel: channels
        )
    }

    private static func makeVoiceSample(
        time: Double,
        channel: Int,
        duration _: TimeInterval,
        noise: inout SeededNoise
    ) -> Float {
        let phraseTime = time.truncatingRemainder(dividingBy: 3.2)
        let syllableTime = phraseTime.truncatingRemainder(dividingBy: 0.42)
        let isSpeaking = phraseTime < 2.35 && syllableTime < 0.31
        guard isSpeaking else {
            return noise.nextSignedFloat() * 0.006
        }

        let envelope = smoothPulse(syllableTime / 0.31)
        let base = 118.0 + 28.0 * sin(time * 0.7)
        let channelOffset = channel == 0 ? 0.0 : 1.3
        let sample =
            sin((base + channelOffset) * .pi * 2 * time) * 0.34 +
            sin((base * 2.18) * .pi * 2 * time) * 0.20 +
            sin((base * 3.41) * .pi * 2 * time) * 0.10 +
            Double(noise.nextSignedFloat()) * 0.035
        return Float(sample * envelope * 0.72)
    }

    private static func makePodcastSample(
        time: Double,
        channel: Int,
        duration _: TimeInterval,
        noise: inout SeededNoise
    ) -> Float {
        let section = Int(time / 12).isMultiple(of: 3)
        let roomTone = Double(noise.nextSignedFloat()) * 0.008
        let voice = makeVoiceSample(
            time: time + (section ? 0 : 0.37),
            channel: channel,
            duration: 0,
            noise: &noise
        )
        let breath = sin(time * .pi * 2 * 2.2) * 0.018
        return Float(min(max(Double(voice) * (section ? 0.72 : 1.0) + breath + roomTone, -0.9), 0.9))
    }

    private static func makeMusicSample(
        time: Double,
        channel: Int,
        duration _: TimeInterval,
        noise: inout SeededNoise
    ) -> Float {
        let bar = time.truncatingRemainder(dividingBy: 2.0)
        let kick = exp(-bar * 18) * sin(54 * .pi * 2 * time) * 0.62
        let hatPhase = time.truncatingRemainder(dividingBy: 0.25)
        let hat = hatPhase < 0.045 ? Double(noise.nextSignedFloat()) * exp(-hatPhase * 58) * 0.16 : 0
        let bass = sin(82.41 * .pi * 2 * time) * 0.21
        let padFrequency = channel == 0 ? 220.0 : 277.18
        let pad = sin(padFrequency * .pi * 2 * time + sin(time * 0.8) * 0.2) * 0.12
        let sidechain = 0.72 + 0.28 * (1 - exp(-bar * 7))
        return Float(min(max((kick + bass + pad + hat) * sidechain, -0.95), 0.95))
    }

    private static func makeTransientSample(
        time: Double,
        channel _: Int,
        duration _: TimeInterval,
        noise: inout SeededNoise
    ) -> Float {
        let grid = 0.5
        let phase = time.truncatingRemainder(dividingBy: grid)
        let click = phase < 0.022 ? exp(-phase * 170) * Double(noise.nextSignedFloat()) * 0.85 : 0
        let tone = phase < 0.09 ? sin((660 + sin(time * 2) * 40) * .pi * 2 * time) * exp(-phase * 36) * 0.32 : 0
        return Float(min(max(click + tone, -0.98), 0.98))
    }

    private static func smoothPulse(_ progress: Double) -> Double {
        let x = min(max(progress, 0), 1)
        let attack = min(x / 0.18, 1)
        let release = min((1 - x) / 0.24, 1)
        return min(attack * attack * (3 - 2 * attack), release * release * (3 - 2 * release))
    }

    private static func writeNativeAudioFixture(_ buffer: DecodedAudioBuffer, to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.sampleRate,
                channels: AVAudioChannelCount(buffer.channelCount),
                interleaved: false
            ),
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(buffer.frameCount)
            ),
            let floatChannelData = pcmBuffer.floatChannelData
        else {
            throw BuilderError.failed("could not create native fixture audio buffer")
        }

        pcmBuffer.frameLength = AVAudioFrameCount(buffer.frameCount)
        for channelIndex in 0..<buffer.channelCount {
            let source = channelIndex < buffer.samplesByChannel.count ? buffer.samplesByChannel[channelIndex] : []
            for frameIndex in 0..<buffer.frameCount {
                floatChannelData[channelIndex][frameIndex] = frameIndex < source.count ? source[frameIndex] : 0
            }
        }

        try FileManager.default.removeFixtureItemIfPresent(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcmBuffer)
    }

    private static func writeCompressedFixture(
        _ buffer: DecodedAudioBuffer,
        to url: URL,
        fallbackSourceWAV: URL?
    ) throws {
        do {
            try CompressedAudioFileWriter.write(buffer, to: url)
        } catch {
            let fallbackWAV: URL
            var shouldRemoveFallbackWAV = false
            if let fallbackSourceWAV {
                fallbackWAV = fallbackSourceWAV
            } else {
                fallbackWAV = url
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-fallback-source.wav")
                try WAVFileWriter.write(
                    DecodedAudioBuffer(
                        url: fallbackWAV,
                        sampleRate: buffer.sampleRate,
                        channelCount: buffer.channelCount,
                        frameCount: buffer.frameCount,
                        samplesByChannel: buffer.samplesByChannel
                    ),
                    to: fallbackWAV
                )
                shouldRemoveFallbackWAV = true
            }
            defer {
                if shouldRemoveFallbackWAV {
                    try? FileManager.default.removeItem(at: fallbackWAV)
                }
            }

            do {
                try runAFConvert(sourceURL: fallbackWAV, destinationURL: url)
            } catch let afConvertError {
                do {
                    try runFFmpeg(sourceURL: fallbackWAV, destinationURL: url)
                } catch let ffmpegError {
                    throw BuilderError.failed(
                        "compressed encode failed for \(url.lastPathComponent): " +
                            "AVFoundation=\(error.localizedDescription); " +
                            "afconvert=\(afConvertError); ffmpeg=\(ffmpegError)"
                    )
                }
            }
        }
        try setStableModificationDate(at: url, offset: Int(url.lastPathComponent.prefix(18).suffix(3)) ?? 0)
    }

    private static func runAFConvert(sourceURL: URL, destinationURL: URL) throws {
        let fileType: String
        let dataFormat: String
        switch destinationURL.pathExtension.lowercased() {
        case "mp3":
            fileType = "MPG3"
            dataFormat = ".mp3"
        case "m4a", "aac":
            fileType = "m4af"
            dataFormat = "aac"
        default:
            throw BuilderError.failed("afconvert fallback does not support \(destinationURL.pathExtension)")
        }

        try FileManager.default.removeFixtureItemIfPresent(at: destinationURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", fileType,
            "-d", dataFormat,
            sourceURL.path,
            destinationURL.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? "unknown afconvert failure"
            throw BuilderError.failed("afconvert failed for \(destinationURL.lastPathComponent): \(errorText)")
        }
    }

    private static func runFFmpeg(sourceURL: URL, destinationURL: URL) throws {
        let ffmpegCandidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        guard let ffmpegPath = ffmpegCandidates.first(where: FileManager.default.fileExists(atPath:)) else {
            throw BuilderError.failed("ffmpeg is not installed")
        }

        let codecArguments: [String]
        switch destinationURL.pathExtension.lowercased() {
        case "mp3":
            codecArguments = ["-codec:a", "libmp3lame", "-b:a", "192k"]
        case "m4a", "aac":
            codecArguments = ["-codec:a", "aac", "-b:a", "192k"]
        case "flac":
            codecArguments = ["-codec:a", "flac"]
        default:
            throw BuilderError.failed("ffmpeg fallback does not support \(destinationURL.pathExtension)")
        }

        try FileManager.default.removeFixtureItemIfPresent(at: destinationURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            sourceURL.path,
        ] + codecArguments + [
            destinationURL.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? "unknown ffmpeg failure"
            throw BuilderError.failed("ffmpeg failed for \(destinationURL.lastPathComponent): \(errorText)")
        }
    }

    private static func writeManifest(
        rootDirectory: URL,
        profile: FixtureProfile,
        audio: [GeneratedAudio],
        projects: [GeneratedProject]
    ) throws {
        let manifest = FixtureManifest(
            schemaVersion: 1,
            fixtureVersion: "v1",
            profile: profile.rawValue,
            generatedBy: "Soundtime ShippabilityFixtureBuilder",
            namingScheme: expectedNamingScheme,
            supportedImportFormatsCovered: expectedSupportedImportFormatsCovered,
            recognizedUnsupportedFormatsCovered: expectedRecognizedUnsupportedFormatsCovered,
            audio: audio.map { item in
                FixtureManifest.Entry(
                    id: item.id,
                    role: item.role,
                    path: relativePath(item.url, from: rootDirectory),
                    format: item.format.rawValue,
                    durationSeconds: item.duration,
                    trackCount: nil,
                    projectReady: item.projectReady,
                    importExpectation: item.importExpectation
                )
            },
            projects: projects.map { project in
                FixtureManifest.Entry(
                    id: project.id,
                    role: project.role,
                    path: relativePath(project.url, from: rootDirectory),
                    format: nil,
                    durationSeconds: project.duration,
                    trackCount: project.trackCount,
                    projectReady: true,
                    importExpectation: nil
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: rootDirectory.appendingPathComponent("fixtures-manifest.json"),
            options: [.atomic]
        )
    }

    private static func writeReadme(rootDirectory: URL) throws {
        let readme = """
        # Soundtime Shippability Fixtures

        Generated by `swift run Soundtime --build-shippability-fixtures`.

        File naming:
        - `st-ship-audio-NNN-role-duration.ext`
        - `st-ship-project-NNN-scenario.soundtime`

        The fixture projects intentionally include compact launch waveform previews,
        edit timelines, mute state, compressed-import metadata, and transcript data.
        They are deterministic and should be regenerated rather than hand-edited.
        """
        try readme.write(
            to: rootDirectory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func verifyExistingFixtures(rootDirectory: URL, profile: FixtureProfile) throws {
        let manifestURL = rootDirectory.appendingPathComponent("fixtures-manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: manifestData)

        try require(manifest.schemaVersion == 1, "unexpected fixture manifest schema \(manifest.schemaVersion)")
        try require(manifest.fixtureVersion == "v1", "unexpected fixture version \(manifest.fixtureVersion)")
        try require(manifest.profile == profile.rawValue, "fixture profile drifted: \(manifest.profile)")
        try require(manifest.namingScheme == expectedNamingScheme, "fixture naming scheme drifted")
        try require(
            manifest.supportedImportFormatsCovered == expectedSupportedImportFormatsCovered,
            "supported import format coverage drifted"
        )
        try require(
            manifest.recognizedUnsupportedFormatsCovered == expectedRecognizedUnsupportedFormatsCovered,
            "recognized unsupported format coverage drifted"
        )
        try verifyAudioManifest(manifest.audio, rootDirectory: rootDirectory, profile: profile)
        try verifyProjectManifest(manifest.projects, rootDirectory: rootDirectory, profile: profile)
    }

    private static func verifyAudioManifest(
        _ entries: [FixtureManifest.Entry],
        rootDirectory: URL,
        profile: FixtureProfile
    ) throws {
        let expectedAudioFixtures = expectedAudioFixtures(for: profile)
        try require(entries.count == expectedAudioFixtures.count, "audio fixture count drifted")
        try require(Set(entries.map(\.id)).count == entries.count, "audio fixture IDs are not unique")
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for expected in expectedAudioFixtures {
            guard let entry = entriesByID[expected.id] else {
                throw BuilderError.failed("missing audio fixture \(expected.id)")
            }

            try require(entry.role == expected.role, "\(expected.id) role drifted")
            try require(entry.path == expected.path, "\(expected.id) path drifted")
            try require(entry.format == expected.format.rawValue, "\(expected.id) format drifted")
            try require(entry.trackCount == nil, "\(expected.id) unexpectedly has track count")
            try require(entry.projectReady == expected.projectReady, "\(expected.id) projectReady drifted")
            try require(
                entry.importExpectation == expected.importExpectation,
                "\(expected.id) import expectation drifted"
            )
            try require(
                approximately(entry.durationSeconds ?? -1, expected.durationSeconds, tolerance: 0.75),
                "\(expected.id) duration drifted: \(entry.durationSeconds ?? -1)"
            )

            let url = rootDirectory.appendingPathComponent(entry.path)
            try require(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
            switch expected.importExpectation {
            case .importable:
                try require(AudioAssetImporter.canImport(url), "\(url.lastPathComponent) should be importable")
                if expected.format == .wav {
                    try require(WAVAudioDecoder.canDecode(url), "\(url.lastPathComponent) is not decodable as WAV")
                    let info = try WAVAudioDecoder.inspect(url: url)
                    try require(
                        approximately(info.duration, expected.durationSeconds, tolerance: 0.02),
                        "\(url.lastPathComponent) WAV duration drifted"
                    )
                } else {
                    let info = try AudioAssetImporter.inspectSynchronously(url: url)
                    try require(info.format == expected.format, "\(url.lastPathComponent) inspected as \(info.format)")
                    try require(
                        approximately(info.duration ?? -1, expected.durationSeconds, tolerance: 0.75),
                        "\(url.lastPathComponent) did not expose expected duration"
                    )
                }
            case .recognizedUnsupported:
                try require(!AudioAssetImporter.canImport(url), "\(url.lastPathComponent) should not be importable")
                try require(
                    AudioAssetFormat.inferred(from: url) == expected.format,
                    "\(url.lastPathComponent) unsupported format inference drifted"
                )
            }
        }
    }

    private static func verifyProjectManifest(
        _ entries: [FixtureManifest.Entry],
        rootDirectory: URL,
        profile: FixtureProfile
    ) throws {
        let expectedProjectFixtures = expectedProjectFixtures(for: profile)
        try require(entries.count == expectedProjectFixtures.count, "project fixture count drifted")
        try require(Set(entries.map(\.id)).count == entries.count, "project fixture IDs are not unique")
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for expected in expectedProjectFixtures {
            guard let entry = entriesByID[expected.id] else {
                throw BuilderError.failed("missing project fixture \(expected.id)")
            }

            try require(entry.role == expected.role, "\(expected.id) role drifted")
            try require(entry.path == expected.path, "\(expected.id) path drifted")
            try require(entry.format == nil, "\(expected.id) unexpectedly has audio format")
            try require(entry.trackCount == expected.trackCount, "\(expected.id) track count drifted")
            try require(entry.projectReady == true, "\(expected.id) projectReady drifted")
            try require(
                approximately(entry.durationSeconds ?? -1, expected.durationSeconds, tolerance: 0.05),
                "\(expected.id) duration drifted: \(entry.durationSeconds ?? -1)"
            )

            let url = rootDirectory.appendingPathComponent(entry.path)
            try require(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
            let loaded = try SoundtimeProjectStore.loadLaunchPreview(from: url)
            try require(loaded.tracks.count == expected.trackCount, "\(url.lastPathComponent) track count mismatch")
            try require(
                loaded.tracks.allSatisfy { $0.waveformPreview != nil },
                "\(url.lastPathComponent) has tracks without launch waveform previews"
            )
        }
    }

    private static func approximately(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func relativePath(_ url: URL, from rootDirectory: URL) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            return path
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func setStableModificationDate(at url: URL, offset: Int) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: stableModificationDate.addingTimeInterval(TimeInterval(offset))],
            ofItemAtPath: url.path
        )
    }

    private static func uuid(_ value: Int) -> UUID {
        let suffix = String(format: "%012X", value)
        return UUID(uuidString: "5354494D-4546-4000-9000-\(suffix)")!
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw BuilderError.failed(message)
        }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw BuilderError.failed(message)
        }
        return value
    }
}

private struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }

    mutating func nextSignedFloat() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let value = Double((state >> 40) & 0xFF_FFFF) / Double(0xFF_FFFF)
        return Float(value * 2 - 1)
    }
}

private extension FileManager {
    func removeFixtureItemIfPresent(at url: URL) throws {
        guard fileExists(atPath: url.path) else {
            return
        }
        try removeItem(at: url)
    }
}
