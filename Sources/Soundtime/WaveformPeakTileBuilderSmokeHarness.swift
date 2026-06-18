import Foundation

enum WaveformPeakTileBuilderSmokeHarness {
    private enum SmokeError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case let .failed(message):
                return message
            }
        }
    }

    static func runFromCommandLine(arguments: [String]) throws {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-peak-tile-builder-smoke-\(UUID().uuidString)", isDirectory: true)
        let wavURL = rootDirectory.appendingPathComponent("synthetic.wav")
        defer {
            try? FileManager.default.removeItem(at: rootDirectory)
        }

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try writeSyntheticWAV(to: wavURL)

        let store = WaveformDiskCacheStore(rootDirectory: rootDirectory.appendingPathComponent("cache", isDirectory: true))
        let result = try WaveformPeakTileBuilder.buildWAVPeakLevel(
            url: wavURL,
            framesPerBin: 64,
            framesPerTile: 256,
            level: 0,
            channelMode: .monoMix,
            shouldYieldForPlayback: false
        )
        try verifyBuiltTiles(result)

        let manifest = try store.savePeakLevel(result)
        let loadedManifest = try store.loadManifest(for: result.fingerprint)
        try require(loadedManifest == manifest, "saved peak-level manifest did not reload")
        let loadedTiles = try store.loadPeakLevel(manifest: manifest, level: result.level)
        try verifyLoadedTiles(loadedTiles, expected: result.tiles)

        let checks = [
            "synthetic WAV peak tile build",
            "peak tile binary write",
            "peak tile binary read",
            "peak tile manifest validation",
        ]
        if let reportURL = StabilityReportWriter.writePassedSuite(
            name: "waveform-peak-tile-builder-smoke",
            startedAtNanoseconds: startedAtNanoseconds,
            checks: checks,
            metadata: ["rendererIntegration": "disabled"],
            arguments: arguments
        ) {
            print("wrote stability report: \(reportURL.path)")
        }
        print("Soundtime waveform peak tile builder smoke passed")
    }

    private static func writeSyntheticWAV(to url: URL) throws {
        let frameCount = 1_024
        let left = (0..<frameCount).map { frame -> Float in
            frame.isMultiple(of: 2) ? -0.75 : 0.75
        }
        let right = (0..<frameCount).map { frame -> Float in
            frame.isMultiple(of: 2) ? 0.50 : -0.50
        }
        let buffer = DecodedAudioBuffer(
            url: url,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: frameCount,
            samplesByChannel: [left, right]
        )
        try WAVFileWriter.write(buffer, to: url)
    }

    private static func verifyBuiltTiles(_ result: WaveformPeakLevelBuildResult) throws {
        try require(result.fileInfo.frameCount == 1_024, "synthetic WAV frame count mismatch")
        try require(result.level.tileCount == 4, "peak tile level should contain four tiles")
        try require(result.tiles.count == 4, "builder did not return all peak tiles")
        try require(result.level.framesPerBin == 64, "builder level framesPerBin mismatch")
        try require(result.level.framesPerTile == 256, "builder level framesPerTile mismatch")
        try require(result.level.fileName == "peak-monoMix-l000.bin", "unexpected level file name")

        for tile in result.tiles {
            try require(tile.bins.count == 4, "each synthetic tile should contain four bins")
            for bin in tile.bins {
                try require(bin.minimumSample < -0.70, "peak bin did not capture negative sample")
                try require(bin.maximumSample > 0.70, "peak bin did not capture positive sample")
                try require(bin.rmsSample > 0.40, "peak bin RMS should be non-trivial")
            }
        }
    }

    private static func verifyLoadedTiles(_ loadedTiles: [WaveformPeakTile], expected: [WaveformPeakTile]) throws {
        try require(loadedTiles.count == expected.count, "loaded tile count mismatch")
        for (loadedTile, expectedTile) in zip(loadedTiles, expected) {
            try require(loadedTile.descriptor.address == expectedTile.descriptor.address, "loaded tile address mismatch")
            try require(loadedTile.bins.count == expectedTile.bins.count, "loaded tile bin count mismatch")
            for (loadedBin, expectedBin) in zip(loadedTile.bins, expectedTile.bins) {
                try require(abs(loadedBin.minimumSample - expectedBin.minimumSample) < 0.000_01, "minimum sample did not round-trip")
                try require(abs(loadedBin.maximumSample - expectedBin.maximumSample) < 0.000_01, "maximum sample did not round-trip")
                try require(abs(loadedBin.rmsSample - expectedBin.rmsSample) < 0.000_01, "RMS sample did not round-trip")
            }
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw SmokeError.failed(message)
        }
    }
}
