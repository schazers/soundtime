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
        XCTAssertTimestamp(snapshot.hostTimestamp, 12.5 + Double(16) / 48_000)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertEqual(snapshot.renderedFrameCount, 16)
        XCTAssertEqual(snapshot.underrunCount, 0)
        XCTAssertEqual(snapshot.droppedCommandCount, 0)

        soundtime_audio_core_seek(engine, 90)
        renderSilence(engine: engine, channelCount: 2, frameCount: 20, hostTimestamp: 12.75)

        snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 100)
        XCTAssertTimestamp(snapshot.hostTimestamp, 12.75 + Double(10) / 48_000)
        XCTAssertEqual(snapshot.renderedFrameCount, 36)
        XCTAssertFalse(snapshot.isPlaying)
    }

    func testInterleavedSourceRendersWithGain() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var samples: [Float] = [
            0.10, -0.20,
            0.30, -0.40,
            0.50, -0.60,
        ]
        let didLoad = samples.withUnsafeMutableBufferPointer { sampleBuffer in
            soundtime_audio_core_set_interleaved_source(
                engine,
                sampleBuffer.baseAddress,
                3,
                2,
                48_000
            )
        }
        XCTAssertTrue(didLoad)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_set_gain(engine, 0.5)
        soundtime_audio_core_play(engine)

        let output = render(engine: engine, channelCount: 2, frameCount: 2, hostTimestamp: 3.25)

        XCTAssertEqual(output[0], [0.05, 0.15])
        XCTAssertEqual(output[1], [-0.10, -0.20])

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 2)
        XCTAssertEqual(snapshot.frameCount, 3)
        XCTAssertTimestamp(snapshot.hostTimestamp, 3.25 + Double(2) / 48_000)
        XCTAssertTrue(snapshot.isPlaying)
    }

    func testPlanarSourceRendersWithoutCallerInterleave() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var left: [Float] = [0.25, 0.50, 0.75]
        var right: [Float] = [-0.25, -0.50, -0.75]
        let didLoad = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_set_planar_source(
                        engine,
                        channelPointers.baseAddress,
                        3,
                        2,
                        48_000
                    )
                }
            }
        }
        XCTAssertTrue(didLoad)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let output = render(engine: engine, channelCount: 2, frameCount: 3, hostTimestamp: 1.5)

        XCTAssertEqual(output[0], [0.25, 0.50, 0.75])
        XCTAssertEqual(output[1], [-0.25, -0.50, -0.75])
    }

    func testPreparedSourceCanBePublishedAfterCreation() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var left: [Float] = [0.10, 0.20]
        var right: [Float] = [0.30, 0.40]
        let preparedSource = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        2,
                        2,
                        48_000
                    )
                }
            }
        }
        let source = try XCTUnwrap(preparedSource)
        defer {
            soundtime_audio_core_source_destroy(source)
        }

        XCTAssertTrue(soundtime_audio_core_set_prepared_source(engine, source))
        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let output = render(engine: engine, channelCount: 2, frameCount: 2, hostTimestamp: 9)
        XCTAssertEqual(output[0], [0.10, 0.20])
        XCTAssertEqual(output[1], [0.30, 0.40])
    }

    func testTransportRampIsSampleAccurate() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var samples: [Float] = [
            1, 1,
            1, 1,
            1, 1,
            1, 1,
            1, 1,
            1, 1,
            1, 1,
            1, 1,
        ]
        let didLoad = samples.withUnsafeMutableBufferPointer { sampleBuffer in
            soundtime_audio_core_set_interleaved_source(
                engine,
                sampleBuffer.baseAddress,
                8,
                2,
                10
            )
        }
        XCTAssertTrue(didLoad)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0.2)
        soundtime_audio_core_play(engine)

        var output = render(engine: engine, channelCount: 2, frameCount: 3, hostTimestamp: 0)
        XCTAssertEqual(output[0], [0.5, 1, 1])
        XCTAssertEqual(output[1], [0.5, 1, 1])

        soundtime_audio_core_pause(engine)
        output = render(engine: engine, channelCount: 2, frameCount: 3, hostTimestamp: 0.3)
        XCTAssertEqual(output[0], [0.5, 0, 0])
        XCTAssertEqual(output[1], [0.5, 0, 0])

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 3)
        XCTAssertFalse(snapshot.isPlaying)
    }

    func testPreparedTracksRenderSampleSynchronously() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var left: [Float] = [0.10, 0.20, -0.30]
        var right: [Float] = [0.40, -0.50, 0.60]
        let preparedSource = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        3,
                        2,
                        48_000
                    )
                }
            }
        }
        let source = try XCTUnwrap(preparedSource)
        defer {
            soundtime_audio_core_source_destroy(source)
        }

        var tracks = [
            SoundtimeAudioCoreTrackConfig(source: source, gain: 1),
            SoundtimeAudioCoreTrackConfig(source: source, gain: 1),
        ]
        let didLoad = tracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_set_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        }
        XCTAssertTrue(didLoad)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let output = render(engine: engine, channelCount: 2, frameCount: 3, hostTimestamp: 4)
        XCTAssertEqual(output[0], [0.20, 0.40, -0.60])
        XCTAssertEqual(output[1], [0.80, -1.00, 1.20])
    }

    func testPreparedTrackUpdateDoesNotResetTransport() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var left: [Float] = [1, 1, 1, 1]
        var right: [Float] = [1, 1, 1, 1]
        let preparedSource = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        4,
                        2,
                        48_000
                    )
                }
            }
        }
        let source = try XCTUnwrap(preparedSource)
        defer {
            soundtime_audio_core_source_destroy(source)
        }

        var tracks = [SoundtimeAudioCoreTrackConfig(source: source, gain: 1)]
        XCTAssertTrue(tracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_set_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        })

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)
        _ = render(engine: engine, channelCount: 2, frameCount: 2, hostTimestamp: 1)

        tracks[0].gain = 0.25
        XCTAssertTrue(tracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_update_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        })

        var snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 2)
        XCTAssertTrue(snapshot.isPlaying)

        let output = render(engine: engine, channelCount: 2, frameCount: 1, hostTimestamp: 1.1)
        XCTAssertEqual(output[0], [0.25])
        XCTAssertEqual(output[1], [0.25])

        snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 3)
        XCTAssertTrue(snapshot.isPlaying)
    }

    func testPauseAtFramePinsTransportAfterRamp() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var samples: [Float] = [
            1, 1,
            1, 1,
            1, 1,
            1, 1,
            1, 1,
            1, 1,
        ]
        let didLoad = samples.withUnsafeMutableBufferPointer { sampleBuffer in
            soundtime_audio_core_set_interleaved_source(
                engine,
                sampleBuffer.baseAddress,
                6,
                2,
                10
            )
        }
        XCTAssertTrue(didLoad)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0.2)
        soundtime_audio_core_play(engine)
        _ = render(engine: engine, channelCount: 2, frameCount: 3, hostTimestamp: 0)

        soundtime_audio_core_pause_at(engine, 3)
        let output = render(engine: engine, channelCount: 2, frameCount: 3, hostTimestamp: 0.3)
        XCTAssertEqual(output[0], [0.5, 0, 0])
        XCTAssertEqual(output[1], [0.5, 0, 0])

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 3)
        XCTAssertFalse(snapshot.isPlaying)
    }

    func testPauseAtFrameDoesNotJumpRenderCursorDuringRamp() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var samples: [Float] = [
            1, 1,
            2, 2,
            3, 3,
            4, 4,
            5, 5,
            6, 6,
        ]
        let didLoad = samples.withUnsafeMutableBufferPointer { sampleBuffer in
            soundtime_audio_core_set_interleaved_source(
                engine,
                sampleBuffer.baseAddress,
                6,
                2,
                10
            )
        }
        XCTAssertTrue(didLoad)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)
        _ = render(engine: engine, channelCount: 2, frameCount: 4, hostTimestamp: 0)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0.2)
        soundtime_audio_core_pause_at(engine, 2)
        let output = render(engine: engine, channelCount: 2, frameCount: 3, hostTimestamp: 0.4)
        XCTAssertEqual(output[0], [2.5, 0, 0])
        XCTAssertEqual(output[1], [2.5, 0, 0])

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 2)
        XCTAssertFalse(snapshot.isPlaying)
    }

    func testRenderPublishesClockSamples() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var samples: [Float] = [
            1, 1,
            1, 1,
            1, 1,
            1, 1,
        ]
        let didLoad = samples.withUnsafeMutableBufferPointer { sampleBuffer in
            soundtime_audio_core_set_interleaved_source(
                engine,
                sampleBuffer.baseAddress,
                4,
                2,
                48_000
            )
        }
        XCTAssertTrue(didLoad)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        _ = render(engine: engine, channelCount: 2, frameCount: 2, hostTimestamp: 2.0)
        _ = render(engine: engine, channelCount: 2, frameCount: 2, hostTimestamp: 2.5)

        var firstSample = SoundtimeAudioCoreClockSample()
        var secondSample = SoundtimeAudioCoreClockSample()
        XCTAssertTrue(soundtime_audio_core_pop_clock_sample(engine, &firstSample))
        XCTAssertTrue(soundtime_audio_core_pop_clock_sample(engine, &secondSample))
        XCTAssertFalse(soundtime_audio_core_pop_clock_sample(engine, &secondSample))

        XCTAssertEqual(firstSample.frameIndex, 2)
        XCTAssertEqual(firstSample.renderedFrameCount, 2)
        XCTAssertTimestamp(firstSample.hostTimestamp, 2.0 + Double(2) / 48_000)
        XCTAssertTrue(firstSample.isPlaying)

        XCTAssertEqual(secondSample.frameIndex, 4)
        XCTAssertEqual(secondSample.renderedFrameCount, 4)
        XCTAssertTimestamp(secondSample.hostTimestamp, 2.5 + Double(2) / 48_000)
        XCTAssertFalse(secondSample.isPlaying)
    }

    private func XCTAssertTimestamp(
        _ actual: Double,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, accuracy: 1e-12, file: file, line: line)
    }

    private func renderSilence(
        engine: OpaquePointer,
        channelCount: Int,
        frameCount: Int,
        hostTimestamp: Double
    ) {
        let output = render(
            engine: engine,
            channelCount: channelCount,
            frameCount: frameCount,
            hostTimestamp: hostTimestamp
        )
        XCTAssertEqual(output[0], [Float](repeating: 0, count: frameCount))
        XCTAssertEqual(output[1], [Float](repeating: 0, count: frameCount))
    }

    private func render(
        engine: OpaquePointer,
        channelCount: Int,
        frameCount: Int,
        hostTimestamp: Double
    ) -> [[Float]] {
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
                    soundtime_audio_core_render_at_host_time(
                        engine,
                        outputs.baseAddress,
                        UInt32(channelCount),
                        UInt32(frameCount),
                        hostTimestamp
                    )
                }
            }
        }

        return [left, right]
    }
}
