import AppKit
import Foundation

@MainActor
enum AudioExportUIContractSmokeHarness {
    static func runFromCommandLine(arguments: [String]) throws {
        let mixOptions = AudioExportOptionsAccessoryView(
            includesCompressedOptions: true,
            includesStemOptions: false
        )
        try require(
            mixOptions.wavEncoding == .pcm24,
            "mixdown options did not default to 24-bit PCM"
        )
        try require(
            mixOptions.compressedQuality == .standard,
            "mixdown options did not default to standard compressed quality"
        )

        let stemOptions = AudioExportOptionsAccessoryView(
            includesCompressedOptions: false,
            includesStemOptions: true
        )
        try require(
            stemOptions.stemOptions == .v1Default,
            "stem options did not default to all tracks, post-fader"
        )

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundtime-ui-contract.wav")
        let request = AudioExportRequest(
            projectName: "UI Contract",
            scope: .fullMixdown,
            format: .wav,
            destinationURL: destinationURL
        )
        let controller = AudioExportWindowController()
        controller.update(progress: .initial(request: request))
        var snapshot = controller.smokeSnapshot()
        try require(snapshot.stageTitle == "Full Mixdown Export", "progress title is not scope-specific")
        try require(snapshot.cancelTitle == "Cancel", "active export did not offer cancellation")
        try require(snapshot.cancelEnabled, "active export cancellation was disabled")

        controller.markCancellationRequested()
        snapshot = controller.smokeSnapshot()
        try require(snapshot.cancelTitle == "Canceling...", "canceling state was not visible")
        try require(!snapshot.cancelEnabled, "cancel button remained enabled after cancellation")

        controller.update(progress: AudioExportProgress(
            jobID: request.id,
            request: request,
            stage: .completed,
            fractionCompleted: 1,
            message: "Export complete",
            outputURLs: [destinationURL]
        ))
        snapshot = controller.smokeSnapshot()
        try require(snapshot.cancelTitle == "Close", "completed export did not offer Close")
        try require(snapshot.revealVisible, "completed export did not offer Reveal")
        try require(snapshot.percent == 100, "completed export did not show 100 percent")

        let supportedCompressedCount = AudioExportFormat.allCases.filter {
            $0.isCompressed && $0.isSystemEncoderAvailable
        }.count
        try require(
            supportedCompressedCount > 0,
            "no system compressed encoder is available to the export UI"
        )

        print("Soundtime audio export UI contract smoke passed")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw AudioExportUIContractSmokeFailure(message)
        }
    }
}

private struct AudioExportUIContractSmokeFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
