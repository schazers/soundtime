import SoundtimeAudioCore
import Dispatch
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

    func testRenderPublishesOutputMeterSamples() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var samples: [Float] = [
            0.50, -0.25,
            1.25, -1.50,
            -0.75, 0.25,
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
        soundtime_audio_core_play(engine)

        _ = render(engine: engine, channelCount: 2, frameCount: 3, hostTimestamp: 4.5)

        var meterSample = SoundtimeAudioCoreMeterSample()
        XCTAssertTrue(soundtime_audio_core_pop_meter_sample(engine, &meterSample))
        XCTAssertFalse(soundtime_audio_core_pop_meter_sample(engine, &meterSample))

        let expectedRMS = Float(sqrt(Double(0.25 + 1.5625 + 0.5625) / 3))
        XCTAssertEqual(meterSample.startFrameIndex, 0)
        XCTAssertEqual(meterSample.frameCount, 3)
        XCTAssertEqual(meterSample.renderedFrameCount, 3)
        XCTAssertTimestamp(meterSample.hostTimestamp, 4.5 + Double(3) / 48_000)
        XCTAssertFalse(meterSample.isPlaying)
        XCTAssertEqual(meterSample.leftRMS, expectedRMS, accuracy: 0.000_001)
        XCTAssertEqual(meterSample.rightRMS, expectedRMS, accuracy: 0.000_001)
        XCTAssertEqual(meterSample.leftPeak, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(meterSample.rightPeak, 1.50, accuracy: 0.000_001)
        XCTAssertEqual(meterSample.leftClipPeak, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(meterSample.rightClipPeak, 1.50, accuracy: 0.000_001)
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

    func testWAVByteSourceRendersWithoutFloatPreparation() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var bytes: [UInt8] = [
            0x00, 0x40, 0x00, 0xC0,
            0x00, 0x20, 0x00, 0xE0,
        ]
        let preparedSource = bytes.withUnsafeMutableBufferPointer { byteBuffer in
            soundtime_audio_core_source_create_wav_bytes(
                byteBuffer.baseAddress,
                UInt64(byteBuffer.count),
                0,
                2,
                2,
                48_000,
                4,
                1,
                16
            )
        }
        let source = try XCTUnwrap(preparedSource)
        defer {
            soundtime_audio_core_source_destroy(source)
        }

        XCTAssertTrue(soundtime_audio_core_set_prepared_source(engine, source))
        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let output = render(engine: engine, channelCount: 2, frameCount: 2, hostTimestamp: 2)
        XCTAssertEqual(output[0], [0.5, 0.25])
        XCTAssertEqual(output[1], [-0.5, -0.25])
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

    func testSeparatePreparedCopiesRenderSampleSynchronously() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var firstLeft: [Float] = [0.10, 0.20, -0.30, 0.45]
        var firstRight: [Float] = [0.40, -0.50, 0.60, -0.70]
        var secondLeft = firstLeft
        var secondRight = firstRight

        let firstSource = firstLeft.withUnsafeMutableBufferPointer { leftSamples in
            firstRight.withUnsafeMutableBufferPointer { rightSamples in
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
        let secondSource = secondLeft.withUnsafeMutableBufferPointer { leftSamples in
            secondRight.withUnsafeMutableBufferPointer { rightSamples in
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
        let sourceA = try XCTUnwrap(firstSource)
        let sourceB = try XCTUnwrap(secondSource)
        defer {
            soundtime_audio_core_source_destroy(sourceA)
            soundtime_audio_core_source_destroy(sourceB)
        }

        var tracks = [
            SoundtimeAudioCoreTrackConfig(source: sourceA, gain: 1),
            SoundtimeAudioCoreTrackConfig(source: sourceB, gain: 1),
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

        let output = render(engine: engine, channelCount: 2, frameCount: 4, hostTimestamp: 8)
        XCTAssertEqual(output[0], [0.20, 0.40, -0.60, 0.90])
        XCTAssertEqual(output[1], [0.80, -1.00, 1.20, -1.40])
    }

    func testPreparedSegmentedTracksRenderTimelineEditsWithoutMaterialization() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var left: [Float] = [1, 2, 3, 4, 5, 6]
        var right: [Float] = [-1, -2, -3, -4, -5, -6]
        let preparedSource = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
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

        var segments = [
            SoundtimeAudioCoreSegmentConfig(
                outputStartFrame: 0,
                sourceStartFrame: 0,
                frameCount: 2,
                sourceFrameScale: 1,
                gainStart: 1,
                gainEnd: 1
            ),
            SoundtimeAudioCoreSegmentConfig(
                outputStartFrame: 2,
                sourceStartFrame: 4,
                frameCount: 2,
                sourceFrameScale: 1,
                gainStart: 0.5,
                gainEnd: 1
            ),
        ]
        let didLoad = segments.withUnsafeMutableBufferPointer { segmentBuffer in
            var tracks = [
                SoundtimeAudioCoreSegmentedTrackConfig(
                    source: source,
                    segments: segmentBuffer.baseAddress,
                    segmentCount: UInt32(segmentBuffer.count),
                    gain: 1
                ),
            ]
            return tracks.withUnsafeMutableBufferPointer { trackBuffer in
                soundtime_audio_core_set_prepared_segmented_tracks(
                    engine,
                    trackBuffer.baseAddress,
                    UInt32(trackBuffer.count)
                )
            }
        }
        XCTAssertTrue(didLoad)

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameCount, 4)
        XCTAssertEqual(snapshot.sampleRate, 48_000)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let output = render(engine: engine, channelCount: 2, frameCount: 4, hostTimestamp: 4)
        XCTAssertEqual(output[0], [1, 2, 2.5, 6])
        XCTAssertEqual(output[1], [-1, -2, -2.5, -6])
    }

    func testIdenticalSegmentedTracksSumWithoutPhaseOffset() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var left: [Float] = [0.10, 0.20, 0.30, 0.40, -0.50, -0.60, 0.70, 0.80]
        var right: [Float] = [-0.15, -0.25, -0.35, -0.45, 0.55, 0.65, -0.75, -0.85]
        let preparedSource = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
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

        var segments = [
            SoundtimeAudioCoreSegmentConfig(
                outputStartFrame: 0,
                sourceStartFrame: 0,
                frameCount: 3,
                sourceFrameScale: 1,
                gainStart: 1,
                gainEnd: 1
            ),
            SoundtimeAudioCoreSegmentConfig(
                outputStartFrame: 3,
                sourceStartFrame: 5,
                frameCount: 3,
                sourceFrameScale: 1,
                gainStart: 0.5,
                gainEnd: 1
            ),
        ]
        let didLoad = segments.withUnsafeMutableBufferPointer { segmentBuffer in
            var tracks = [
                SoundtimeAudioCoreSegmentedTrackConfig(
                    source: source,
                    segments: segmentBuffer.baseAddress,
                    segmentCount: UInt32(segmentBuffer.count),
                    gain: 1
                ),
                SoundtimeAudioCoreSegmentedTrackConfig(
                    source: source,
                    segments: segmentBuffer.baseAddress,
                    segmentCount: UInt32(segmentBuffer.count),
                    gain: 1
                ),
            ]
            return tracks.withUnsafeMutableBufferPointer { trackBuffer in
                soundtime_audio_core_set_prepared_segmented_tracks(
                    engine,
                    trackBuffer.baseAddress,
                    UInt32(trackBuffer.count)
                )
            }
        }
        XCTAssertTrue(didLoad)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let output = render(engine: engine, channelCount: 2, frameCount: 6, hostTimestamp: 12)
        XCTAssertEqual(output[0], [0.20, 0.40, 0.60, -0.60, 1.05, 1.60])
        XCTAssertEqual(output[1], [-0.30, -0.50, -0.70, 0.65, -1.125, -1.70])
    }

    func testPreparedTracksWithMixedSampleRatesRenderOnProjectTimeline() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var lowRateSamples: [Float] = [1, 2, 3, 4]
        var highRateSamples: [Float] = [10, 20, 30, 40, 50, 60, 70, 80]

        let lowRateSource = lowRateSamples.withUnsafeMutableBufferPointer { samples in
            var channels = [UnsafePointer(samples.baseAddress)]
            return channels.withUnsafeMutableBufferPointer { channelPointers in
                soundtime_audio_core_source_create_planar(
                    channelPointers.baseAddress,
                    UInt64(samples.count),
                    1,
                    4
                )
            }
        }
        let highRateSource = highRateSamples.withUnsafeMutableBufferPointer { samples in
            var channels = [UnsafePointer(samples.baseAddress)]
            return channels.withUnsafeMutableBufferPointer { channelPointers in
                soundtime_audio_core_source_create_planar(
                    channelPointers.baseAddress,
                    UInt64(samples.count),
                    1,
                    8
                )
            }
        }
        let sourceA = try XCTUnwrap(lowRateSource)
        let sourceB = try XCTUnwrap(highRateSource)
        defer {
            soundtime_audio_core_source_destroy(sourceA)
            soundtime_audio_core_source_destroy(sourceB)
        }

        var tracks = [
            SoundtimeAudioCoreTrackConfig(source: sourceA, gain: 1),
            SoundtimeAudioCoreTrackConfig(source: sourceB, gain: 1),
        ]
        let didLoad = tracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_set_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        }
        XCTAssertTrue(didLoad)

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameCount, 4)
        XCTAssertEqual(snapshot.sampleRate, 4)

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let output = render(engine: engine, channelCount: 2, frameCount: 4, hostTimestamp: 8)
        XCTAssertEqual(output[0], [11, 32, 53, 74])
        XCTAssertEqual(output[1], [11, 32, 53, 74])
    }

    func testPreparedTrackUpdateDoesNotResetTransport() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var left = [Float](repeating: 1, count: 200)
        var right = [Float](repeating: 1, count: 200)
        let preparedSource = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
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

        let output = render(engine: engine, channelCount: 2, frameCount: 145, hostTimestamp: 1.1)
        XCTAssertEqual(output[0].last, 0.25)
        XCTAssertEqual(output[1].last, 0.25)

        snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameIndex, 147)
        XCTAssertTrue(snapshot.isPlaying)
    }

    func testPreparedTrackGainUpdatesRampWithoutClicking() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var left = [Float](repeating: 1, count: 16)
        var right = [Float](repeating: 1, count: 16)
        let preparedSource = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
                        2,
                        1_000
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
        _ = render(engine: engine, channelCount: 2, frameCount: 1, hostTimestamp: 0)

        tracks[0].gain = 0
        XCTAssertTrue(tracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_update_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        })

        var output = render(engine: engine, channelCount: 2, frameCount: 4, hostTimestamp: 0.1)
        XCTAssertEqual(output[0][0], Float(2.0 / 3.0), accuracy: 0.000_001)
        XCTAssertEqual(output[0][1], Float(1.0 / 3.0), accuracy: 0.000_001)
        XCTAssertEqual(output[0][2], 0, accuracy: 0.000_001)
        XCTAssertEqual(output[0][3], 0, accuracy: 0.000_001)

        tracks[0].gain = 1
        XCTAssertTrue(tracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_update_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        })

        output = render(engine: engine, channelCount: 2, frameCount: 4, hostTimestamp: 0.2)
        XCTAssertEqual(output[0][0], Float(1.0 / 3.0), accuracy: 0.000_001)
        XCTAssertEqual(output[0][1], Float(2.0 / 3.0), accuracy: 0.000_001)
        XCTAssertEqual(output[0][2], 1, accuracy: 0.000_001)
        XCTAssertEqual(output[0][3], 1, accuracy: 0.000_001)
    }

    func testManyPreparedTrackGainRampsStaySynchronous() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        let trackCount = 192
        var left = [Float](repeating: 0.001, count: 256)
        var right = [Float](repeating: -0.0005, count: 256)
        let preparedSource = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
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

        var tracks = Array(
            repeating: SoundtimeAudioCoreTrackConfig(source: source, gain: 1),
            count: trackCount
        )
        XCTAssertTrue(tracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_set_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        })

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        var output = render(engine: engine, channelCount: 2, frameCount: 1, hostTimestamp: 0)
        XCTAssertEqual(output[0][0], Float(trackCount) * 0.001, accuracy: 0.000_01)
        XCTAssertEqual(output[1][0], Float(trackCount) * -0.0005, accuracy: 0.000_01)

        for index in tracks.indices {
            tracks[index].gain = 0.5
        }
        XCTAssertTrue(tracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_update_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        })

        output = render(engine: engine, channelCount: 2, frameCount: 145, hostTimestamp: 0.1)
        XCTAssertEqual(try XCTUnwrap(output[0].last), Float(trackCount) * 0.0005, accuracy: 0.000_01)
        XCTAssertEqual(try XCTUnwrap(output[1].last), Float(trackCount) * -0.00025, accuracy: 0.000_01)
    }

    func testPreparedTrackUpdatesCanOverlapRenderBlocks() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var firstLeft = (0..<2_048).map { Float($0 % 97) / 97 }
        var firstRight = firstLeft.map { -$0 }
        var secondLeft = (0..<2_048).map { Float(($0 * 7) % 113) / 113 }
        var secondRight = secondLeft.map { -$0 }

        let firstSource = firstLeft.withUnsafeMutableBufferPointer { leftSamples in
            firstRight.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
                        2,
                        48_000
                    )
                }
            }
        }
        let secondSource = secondLeft.withUnsafeMutableBufferPointer { leftSamples in
            secondRight.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
                        2,
                        48_000
                    )
                }
            }
        }
        let sourceA = try XCTUnwrap(firstSource)
        let sourceB = try XCTUnwrap(secondSource)
        defer {
            soundtime_audio_core_source_destroy(sourceA)
            soundtime_audio_core_source_destroy(sourceB)
        }

        var initialTracks = [
            SoundtimeAudioCoreTrackConfig(source: sourceA, gain: 1),
            SoundtimeAudioCoreTrackConfig(source: sourceB, gain: 0.5),
        ]
        XCTAssertTrue(initialTracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_set_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        })

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let renderQueue = DispatchQueue(label: "SoundtimeAudioCoreTests.renderStress")
        let renderGroup = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let engineBox = AudioCoreEngineBox(engine)

        renderGroup.enter()
        renderQueue.async {
            start.wait()

            var left = [Float](repeating: 0, count: 128)
            var right = [Float](repeating: 0, count: 128)
            for iteration in 0..<2_000 {
                left.withUnsafeMutableBufferPointer { leftSamples in
                    right.withUnsafeMutableBufferPointer { rightSamples in
                        var outputs = [
                            leftSamples.baseAddress,
                            rightSamples.baseAddress,
                        ]
                        outputs.withUnsafeMutableBufferPointer { outputPointers in
                            soundtime_audio_core_render_at_host_time(
                                engineBox.engine,
                                outputPointers.baseAddress,
                                2,
                                UInt32(leftSamples.count),
                                Double(iteration) / 48_000
                            )
                        }
                    }
                }

                if iteration.isMultiple(of: 128) {
                    soundtime_audio_core_seek(engineBox.engine, UInt64((iteration * 13) % 1_500))
                    soundtime_audio_core_play(engineBox.engine)
                }
            }

            renderGroup.leave()
        }

        start.signal()
        for iteration in 0..<2_000 {
            let even = iteration.isMultiple(of: 2)
            let firstGain = Float((iteration % 17) + 1) / 17
            let secondGain = Float((iteration % 23) + 1) / 23
            var tracks = [
                SoundtimeAudioCoreTrackConfig(source: even ? sourceA : sourceB, gain: firstGain),
                SoundtimeAudioCoreTrackConfig(source: even ? sourceB : sourceA, gain: secondGain),
            ]
            XCTAssertTrue(tracks.withUnsafeMutableBufferPointer { trackBuffer in
                soundtime_audio_core_update_prepared_tracks(
                    engine,
                    trackBuffer.baseAddress,
                    UInt32(trackBuffer.count)
                )
            })
        }

        XCTAssertEqual(renderGroup.wait(timeout: .now() + 5), .success)

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameCount, 2_048)
        XCTAssertEqual(snapshot.sampleRate, 48_000)
    }

    func testPublishedSourcesOutliveCallerHandlesDuringRendering() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        soundtime_audio_core_set_transport_ramp_duration(engine, 0)

        func makeSource(seed: Int) -> OpaquePointer? {
            var left = (0..<512).map { frame in
                Float(((frame + seed) % 97) - 48) / 97
            }
            var right = left.map { -$0 }
            return left.withUnsafeMutableBufferPointer { leftSamples in
                right.withUnsafeMutableBufferPointer { rightSamples in
                    var channels = [
                        UnsafePointer(leftSamples.baseAddress),
                        UnsafePointer(rightSamples.baseAddress),
                    ]
                    return channels.withUnsafeMutableBufferPointer { channelPointers in
                        soundtime_audio_core_source_create_planar(
                            channelPointers.baseAddress,
                            UInt64(leftSamples.count),
                            2,
                            48_000
                        )
                    }
                }
            }
        }

        let initialSource = try XCTUnwrap(makeSource(seed: 0))
        var initialTracks = [SoundtimeAudioCoreTrackConfig(source: initialSource, gain: 1)]
        XCTAssertTrue(initialTracks.withUnsafeMutableBufferPointer { trackBuffer in
            soundtime_audio_core_set_prepared_tracks(
                engine,
                trackBuffer.baseAddress,
                UInt32(trackBuffer.count)
            )
        })
        soundtime_audio_core_source_destroy(initialSource)
        soundtime_audio_core_play(engine)

        let renderQueue = DispatchQueue(label: "SoundtimeAudioCoreTests.sourceLifetimeRenderStress")
        let renderGroup = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let engineBox = AudioCoreEngineBox(engine)

        renderGroup.enter()
        renderQueue.async {
            start.wait()

            var left = [Float](repeating: 0, count: 96)
            var right = [Float](repeating: 0, count: 96)
            for iteration in 0..<1_200 {
                left.withUnsafeMutableBufferPointer { leftSamples in
                    right.withUnsafeMutableBufferPointer { rightSamples in
                        var outputs = [
                            leftSamples.baseAddress,
                            rightSamples.baseAddress,
                        ]
                        outputs.withUnsafeMutableBufferPointer { outputPointers in
                            soundtime_audio_core_render_at_host_time(
                                engineBox.engine,
                                outputPointers.baseAddress,
                                2,
                                UInt32(leftSamples.count),
                                Double(iteration) / 48_000
                            )
                        }
                    }
                }
            }

            renderGroup.leave()
        }

        start.signal()
        for iteration in 1...1_200 {
            let source = try XCTUnwrap(makeSource(seed: iteration))
            var tracks = [SoundtimeAudioCoreTrackConfig(
                source: source,
                gain: Float((iteration % 19) + 1) / 19
            )]
            XCTAssertTrue(tracks.withUnsafeMutableBufferPointer { trackBuffer in
                soundtime_audio_core_update_prepared_tracks(
                    engine,
                    trackBuffer.baseAddress,
                    UInt32(trackBuffer.count)
                )
            })
            soundtime_audio_core_source_destroy(source)
        }

        XCTAssertEqual(renderGroup.wait(timeout: .now() + 5), .success)

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.frameCount, 512)
        XCTAssertEqual(snapshot.sampleRate, 48_000)
    }

    func testSegmentedEditGraphsCanOverlapRenderBlocks() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        var firstLeft = (0..<8_192).map { Float($0 % 101) / 101 }
        var firstRight = firstLeft.map { -$0 }
        var secondLeft = (0..<8_192).map { Float(($0 * 11) % 127) / 127 }
        var secondRight = secondLeft.map { -$0 }

        let firstSource = firstLeft.withUnsafeMutableBufferPointer { leftSamples in
            firstRight.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
                        2,
                        48_000
                    )
                }
            }
        }
        let secondSource = secondLeft.withUnsafeMutableBufferPointer { leftSamples in
            secondRight.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
                        2,
                        48_000
                    )
                }
            }
        }
        let sourceA = try XCTUnwrap(firstSource)
        let sourceB = try XCTUnwrap(secondSource)
        defer {
            soundtime_audio_core_source_destroy(sourceA)
            soundtime_audio_core_source_destroy(sourceB)
        }

        func segments(iteration: Int, offset: UInt64) -> [SoundtimeAudioCoreSegmentConfig] {
            let deletedFrames = UInt64((iteration % 41) * 3)
            let fadeFrames = UInt64(64 + (iteration % 5) * 16)
            let gainStart = Float((iteration % 9) + 1) / 9
            let gainEnd = Float((iteration % 13) + 1) / 13
            let spliceStart = UInt64(384 + (iteration % 97))
            return [
                SoundtimeAudioCoreSegmentConfig(
                    outputStartFrame: 0,
                    sourceStartFrame: offset,
                    frameCount: spliceStart,
                    sourceFrameScale: 1,
                    gainStart: 1,
                    gainEnd: gainStart
                ),
                SoundtimeAudioCoreSegmentConfig(
                    outputStartFrame: spliceStart,
                    sourceStartFrame: offset + spliceStart + deletedFrames,
                    frameCount: 2_048 + fadeFrames,
                    sourceFrameScale: 1,
                    gainStart: gainStart,
                    gainEnd: gainEnd
                ),
                SoundtimeAudioCoreSegmentConfig(
                    outputStartFrame: spliceStart + 2_048 + fadeFrames,
                    sourceStartFrame: offset + spliceStart + deletedFrames + 2_048 + fadeFrames,
                    frameCount: 1_024,
                    sourceFrameScale: 1,
                    gainStart: gainEnd,
                    gainEnd: 1
                ),
            ]
        }

        func publish(iteration: Int, resetTransport: Bool) -> Bool {
            var firstSegments = segments(iteration: iteration, offset: UInt64(iteration % 37))
            var secondSegments = segments(iteration: iteration + 19, offset: UInt64(iteration % 53))
            return firstSegments.withUnsafeMutableBufferPointer { firstSegmentBuffer in
                secondSegments.withUnsafeMutableBufferPointer { secondSegmentBuffer in
                    var tracks = [
                        SoundtimeAudioCoreSegmentedTrackConfig(
                            source: iteration.isMultiple(of: 2) ? sourceA : sourceB,
                            segments: firstSegmentBuffer.baseAddress,
                            segmentCount: UInt32(firstSegmentBuffer.count),
                            gain: Float((iteration % 17) + 1) / 17
                        ),
                        SoundtimeAudioCoreSegmentedTrackConfig(
                            source: iteration.isMultiple(of: 2) ? sourceB : sourceA,
                            segments: secondSegmentBuffer.baseAddress,
                            segmentCount: UInt32(secondSegmentBuffer.count),
                            gain: Float((iteration % 23) + 1) / 23
                        ),
                    ]
                    return tracks.withUnsafeMutableBufferPointer { trackBuffer in
                        if resetTransport {
                            return soundtime_audio_core_set_prepared_segmented_tracks(
                                engine,
                                trackBuffer.baseAddress,
                                UInt32(trackBuffer.count)
                            )
                        }

                        return soundtime_audio_core_update_prepared_segmented_tracks(
                            engine,
                            trackBuffer.baseAddress,
                            UInt32(trackBuffer.count)
                        )
                    }
                }
            }
        }

        XCTAssertTrue(publish(iteration: 0, resetTransport: true))
        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let renderQueue = DispatchQueue(label: "SoundtimeAudioCoreTests.segmentedEditRenderStress")
        let renderGroup = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let engineBox = AudioCoreEngineBox(engine)

        renderGroup.enter()
        renderQueue.async {
            start.wait()

            var left = [Float](repeating: 0, count: 192)
            var right = [Float](repeating: 0, count: 192)
            for iteration in 0..<3_000 {
                left.withUnsafeMutableBufferPointer { leftSamples in
                    right.withUnsafeMutableBufferPointer { rightSamples in
                        var outputs = [
                            leftSamples.baseAddress,
                            rightSamples.baseAddress,
                        ]
                        outputs.withUnsafeMutableBufferPointer { outputPointers in
                            soundtime_audio_core_render_at_host_time(
                                engineBox.engine,
                                outputPointers.baseAddress,
                                2,
                                UInt32(leftSamples.count),
                                Double(iteration) / 48_000
                            )
                        }
                    }
                }

                if iteration.isMultiple(of: 173) {
                    soundtime_audio_core_seek(engineBox.engine, UInt64((iteration * 29) % 2_800))
                    soundtime_audio_core_play(engineBox.engine)
                }
            }

            renderGroup.leave()
        }

        start.signal()
        for iteration in 1...3_000 {
            XCTAssertTrue(publish(iteration: iteration, resetTransport: false))
        }

        XCTAssertEqual(renderGroup.wait(timeout: .now() + 5), .success)

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.sampleRate, 48_000)
        XCTAssertGreaterThan(snapshot.frameCount, 3_000)
    }

    func testManySegmentedTrackUpdatesCanOverlapRenderBlocks() throws {
        let engine = try XCTUnwrap(soundtime_audio_core_create())
        defer {
            soundtime_audio_core_destroy(engine)
        }

        let trackCount = 64
        var left = (0..<8_192).map { frame in
            Float(((frame * 17) % 251) - 125) / 251
        }
        var right = (0..<8_192).map { frame in
            Float(((frame * 29) % 257) - 128) / 257
        }
        let source = left.withUnsafeMutableBufferPointer { leftSamples in
            right.withUnsafeMutableBufferPointer { rightSamples in
                var channels = [
                    UnsafePointer(leftSamples.baseAddress),
                    UnsafePointer(rightSamples.baseAddress),
                ]
                return channels.withUnsafeMutableBufferPointer { channelPointers in
                    soundtime_audio_core_source_create_planar(
                        channelPointers.baseAddress,
                        UInt64(leftSamples.count),
                        2,
                        48_000
                    )
                }
            }
        }
        let sourcePointer = try XCTUnwrap(source)
        defer {
            soundtime_audio_core_source_destroy(sourcePointer)
        }

        func makeSegments(trackIndex: Int, iteration: Int) -> [SoundtimeAudioCoreSegmentConfig] {
            let offset = UInt64((trackIndex * 31 + iteration * 17) % 384)
            let deleteSkip = UInt64(96 + (trackIndex + iteration) % 96)
            let fadeGain = Float((trackIndex + iteration) % 11 + 1) / 12
            return [
                SoundtimeAudioCoreSegmentConfig(
                    outputStartFrame: 0,
                    sourceStartFrame: offset,
                    frameCount: 768,
                    sourceFrameScale: 1,
                    gainStart: 1,
                    gainEnd: fadeGain
                ),
                SoundtimeAudioCoreSegmentConfig(
                    outputStartFrame: 768,
                    sourceStartFrame: offset + 768 + deleteSkip,
                    frameCount: 768,
                    sourceFrameScale: 1,
                    gainStart: fadeGain,
                    gainEnd: 1
                ),
                SoundtimeAudioCoreSegmentConfig(
                    outputStartFrame: 1_536,
                    sourceStartFrame: offset + 1_632 + deleteSkip,
                    frameCount: 768,
                    sourceFrameScale: 1,
                    gainStart: 1,
                    gainEnd: 1
                ),
            ]
        }

        func publish(iteration: Int, resetTransport: Bool) -> Bool {
            var allSegments: [SoundtimeAudioCoreSegmentConfig] = []
            var segmentCounts: [Int] = []
            allSegments.reserveCapacity(trackCount * 3)
            segmentCounts.reserveCapacity(trackCount)

            for trackIndex in 0..<trackCount {
                let segments = makeSegments(trackIndex: trackIndex, iteration: iteration)
                segmentCounts.append(segments.count)
                allSegments.append(contentsOf: segments)
            }

            return allSegments.withUnsafeMutableBufferPointer { segmentBuffer in
                guard let segmentBaseAddress = segmentBuffer.baseAddress else {
                    return false
                }

                var segmentOffset = 0
                var tracks: [SoundtimeAudioCoreSegmentedTrackConfig] = []
                tracks.reserveCapacity(trackCount)
                for trackIndex in 0..<trackCount {
                    let segmentCount = segmentCounts[trackIndex]
                    tracks.append(SoundtimeAudioCoreSegmentedTrackConfig(
                        source: sourcePointer,
                        segments: segmentBaseAddress.advanced(by: segmentOffset),
                        segmentCount: UInt32(segmentCount),
                        gain: Float((trackIndex + iteration) % 19 + 1) / 19
                    ))
                    segmentOffset += segmentCount
                }

                return tracks.withUnsafeMutableBufferPointer { trackBuffer in
                    if resetTransport {
                        return soundtime_audio_core_set_prepared_segmented_tracks(
                            engine,
                            trackBuffer.baseAddress,
                            UInt32(trackBuffer.count)
                        )
                    }

                    return soundtime_audio_core_update_prepared_segmented_tracks(
                        engine,
                        trackBuffer.baseAddress,
                        UInt32(trackBuffer.count)
                    )
                }
            }
        }

        XCTAssertTrue(publish(iteration: 0, resetTransport: true))
        soundtime_audio_core_set_transport_ramp_duration(engine, 0)
        soundtime_audio_core_play(engine)

        let renderQueue = DispatchQueue(label: "SoundtimeAudioCoreTests.manySegmentedTracksRenderStress")
        let renderGroup = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let engineBox = AudioCoreEngineBox(engine)

        renderGroup.enter()
        renderQueue.async {
            start.wait()

            var leftOutput = [Float](repeating: 0, count: 128)
            var rightOutput = [Float](repeating: 0, count: 128)
            for iteration in 0..<900 {
                leftOutput.withUnsafeMutableBufferPointer { leftSamples in
                    rightOutput.withUnsafeMutableBufferPointer { rightSamples in
                        var outputs = [
                            leftSamples.baseAddress,
                            rightSamples.baseAddress,
                        ]
                        outputs.withUnsafeMutableBufferPointer { outputPointers in
                            soundtime_audio_core_render_at_host_time(
                                engineBox.engine,
                                outputPointers.baseAddress,
                                2,
                                UInt32(leftSamples.count),
                                Double(iteration) / 48_000
                            )
                        }
                    }
                }

                if iteration.isMultiple(of: 137) {
                    soundtime_audio_core_seek(engineBox.engine, UInt64((iteration * 23) % 1_900))
                    soundtime_audio_core_play(engineBox.engine)
                }
            }

            renderGroup.leave()
        }

        start.signal()
        for iteration in 1...900 {
            XCTAssertTrue(publish(iteration: iteration, resetTransport: false))
        }

        XCTAssertEqual(renderGroup.wait(timeout: .now() + 5), .success)

        let snapshot = soundtime_audio_core_snapshot(engine)
        XCTAssertEqual(snapshot.sampleRate, 48_000)
        XCTAssertGreaterThan(snapshot.frameCount, 2_000)
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

    func testRecordingRingRoundTripsPlanarSamples() throws {
        let ring = try XCTUnwrap(soundtime_audio_core_recording_ring_create(2, 8, 48_000))
        defer {
            soundtime_audio_core_recording_ring_destroy(ring)
        }

        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [10, 20, 30, 40]
        let written = left.withUnsafeBufferPointer { leftSamples in
            right.withUnsafeBufferPointer { rightSamples in
                let inputPointers = [
                    leftSamples.baseAddress,
                    rightSamples.baseAddress,
                ]
                return inputPointers.withUnsafeBufferPointer { inputs in
                    soundtime_audio_core_recording_ring_push_planar(
                        ring,
                        inputs.baseAddress,
                        2,
                        4,
                        123.0
                    )
                }
            }
        }
        XCTAssertEqual(written, 4)
        XCTAssertEqual(soundtime_audio_core_recording_ring_available_frame_count(ring), 4)
        XCTAssertEqual(soundtime_audio_core_recording_ring_channel_count(ring), 2)
        XCTAssertEqual(soundtime_audio_core_recording_ring_sample_rate(ring), 48_000)

        let output = popRecordingRing(ring: ring, channelCount: 2, frameCount: 4)
        XCTAssertEqual(output.samples[0], [1, 2, 3, 4])
        XCTAssertEqual(output.samples[1], [10, 20, 30, 40])
        XCTAssertEqual(output.hostTimestamp, 123.0)
        XCTAssertEqual(soundtime_audio_core_recording_ring_available_frame_count(ring), 0)
    }

    func testRecordingRingCountsDroppedFramesInsteadOfBlocking() throws {
        let ring = try XCTUnwrap(soundtime_audio_core_recording_ring_create(1, 4, 48_000))
        defer {
            soundtime_audio_core_recording_ring_destroy(ring)
        }

        let samples: [Float] = [1, 2, 3, 4, 5, 6]
        let written = samples.withUnsafeBufferPointer { sampleBuffer in
            let inputPointers = [sampleBuffer.baseAddress]
            return inputPointers.withUnsafeBufferPointer { inputs in
                soundtime_audio_core_recording_ring_push_planar(
                    ring,
                    inputs.baseAddress,
                    1,
                    6,
                    1.0
                )
            }
        }

        XCTAssertEqual(written, 4)
        XCTAssertEqual(soundtime_audio_core_recording_ring_dropped_frame_count(ring), 2)
        XCTAssertEqual(popRecordingRing(ring: ring, channelCount: 1, frameCount: 6).samples[0], [1, 2, 3, 4])
    }

    func testRecordingRingResetClearsPendingAndDroppedFrames() throws {
        let ring = try XCTUnwrap(soundtime_audio_core_recording_ring_create(1, 4, 48_000))
        defer {
            soundtime_audio_core_recording_ring_destroy(ring)
        }

        let samples: [Float] = [1, 2, 3, 4, 5]
        _ = samples.withUnsafeBufferPointer { sampleBuffer in
            let inputPointers = [sampleBuffer.baseAddress]
            return inputPointers.withUnsafeBufferPointer { inputs in
                soundtime_audio_core_recording_ring_push_planar(
                    ring,
                    inputs.baseAddress,
                    1,
                    5,
                    1.0
                )
            }
        }

        XCTAssertGreaterThan(soundtime_audio_core_recording_ring_available_frame_count(ring), 0)
        XCTAssertGreaterThan(soundtime_audio_core_recording_ring_dropped_frame_count(ring), 0)

        soundtime_audio_core_recording_ring_reset(ring)
        XCTAssertEqual(soundtime_audio_core_recording_ring_available_frame_count(ring), 0)
        XCTAssertEqual(soundtime_audio_core_recording_ring_dropped_frame_count(ring), 0)
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

    private func popRecordingRing(
        ring: OpaquePointer,
        channelCount: Int,
        frameCount: Int
    ) -> (samples: [[Float]], hostTimestamp: Double) {
        let outputPointers = (0..<channelCount).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        }
        defer {
            for pointer in outputPointers {
                pointer.deallocate()
            }
        }

        var hostTimestamp = 0.0
        let optionalOutputPointers: [UnsafeMutablePointer<Float>?] = outputPointers
        let framesRead = optionalOutputPointers.withUnsafeBufferPointer { pointerBuffer in
            soundtime_audio_core_recording_ring_pop_planar(
                ring,
                pointerBuffer.baseAddress,
                UInt32(channelCount),
                UInt32(frameCount),
                &hostTimestamp
            )
        }
        let samples = outputPointers.map { pointer in
            Array(UnsafeBufferPointer(start: pointer, count: Int(framesRead)))
        }

        return (samples, hostTimestamp)
    }
}

private final class AudioCoreEngineBox: @unchecked Sendable {
    let engine: OpaquePointer

    init(_ engine: OpaquePointer) {
        self.engine = engine
    }
}
