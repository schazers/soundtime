import SoundtimeAudioCore
import XCTest

final class SoundtimeAudioCoreTests: XCTestCase {
    func testTransportCommandsAreConsumedByRender() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        soundtime_audio_core_set_source_info(engine, 100, 2, 48_000)
        soundtime_audio_core_play(engine)

        renderSilence(engine: engine, channelCount: 2, frameCount: 16, hostTimestamp: 12.5)

        var snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 16)
        XCTAssertEqual(snapshot.frameCount, 100)
        XCTAssertEqual(snapshot.sampleRate, 48_000)
        XCTAssertEqual(snapshot.hostTimestamp, 12.5)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertEqual(snapshot.renderedFrameCount, 16)
        XCTAssertEqual(snapshot.underrunCount, 0)
        XCTAssertEqual(snapshot.droppedCommandCount, 0)

        soundtime_audio_core_seek(engine, 90)
        renderSilence(engine: engine, channelCount: 2, frameCount: 20, hostTimestamp: 12.75)

        snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 100)
        XCTAssertEqual(snapshot.hostTimestamp, 12.75)
        XCTAssertEqual(snapshot.renderedFrameCount, 36)
        XCTAssertFalse(snapshot.isPlaying)
    }

    private func renderSilence(
        engine: OpaquePointer,
        channelCount: Int,
        frameCount: Int,
        hostTimestamp: Double
    ) {
        XCTAssertEqual(channelCount, 2)
        var left = [Float](repeating: 1, count: frameCount)
        var right = [Float](repeating: 1, count: frameCount)

        left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var outputPointers = [
                    leftSamples.baseAddress,
                    rightSamples.baseAddress,
                ]
                outputPointers.withUnsafeMutableBufferPointer { outputs in
                    soundtime_audio_core_render_silence_at_host_time(
                        engine,
                        outputs.baseAddress,
                        UInt32(channelCount),
                        UInt32(frameCount),
                        hostTimestamp
                    )
                }
            }
        }

        XCTAssertEqual(left, [Float](repeating: 0, count: frameCount))
        XCTAssertEqual(right, [Float](repeating: 0, count: frameCount))
    }
}
