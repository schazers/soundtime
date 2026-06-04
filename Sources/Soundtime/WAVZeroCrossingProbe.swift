import Foundation

struct WAVZeroCrossingProbe: Sendable {
    private let data: Data
    private let fileInfo: WAVFileInfo
    private let searchRadius: Int

    init(data: Data, fileInfo: WAVFileInfo) {
        self.data = data
        self.fileInfo = fileInfo
        searchRadius = min(max(Int(fileInfo.sampleRate * 0.02), 512), 4_096)
    }

    func nearestFrame(to frame: Int) -> Int {
        do {
            return try AudioZeroCrossingIndex.nearestFrame(
                to: frame,
                in: { frameIndex in
                    try WAVAudioDecoder.mixedSample(
                        in: data,
                        fileInfo: fileInfo,
                        frameIndex: frameIndex
                    )
                },
                frameCount: fileInfo.frameCount,
                searchRadius: searchRadius
            )
        } catch {
            return min(max(frame, 0), fileInfo.frameCount)
        }
    }
}
