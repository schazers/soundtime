#ifndef SOUNDTIME_AUDIO_CORE_H
#define SOUNDTIME_AUDIO_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SoundtimeAudioCoreEngine SoundtimeAudioCoreEngine;
typedef struct SoundtimeAudioCoreSource SoundtimeAudioCoreSource;
typedef struct SoundtimeAudioCoreRecordingRing SoundtimeAudioCoreRecordingRing;

typedef struct SoundtimeAudioCoreSnapshot {
    uint64_t frameIndex;
    uint64_t frameCount;
    double sampleRate;
    double hostTimestamp;
    bool isPlaying;
    uint64_t renderedFrameCount;
    uint64_t underrunCount;
    uint64_t droppedCommandCount;
    uint64_t callbackCount;
    uint64_t lastRenderNanoseconds;
    uint64_t maxRenderNanoseconds;
    uint64_t renderDeadlineMissCount;
    uint64_t lastRenderWorkNanoseconds;
    uint64_t maxRenderWorkNanoseconds;
    uint64_t renderWorkDeadlineMissCount;
    uint64_t callbackSchedulingLateCount;
    uint64_t maxCallbackSchedulingLatenessNanoseconds;
} SoundtimeAudioCoreSnapshot;

typedef struct SoundtimeAudioCoreClockSample {
    uint64_t frameIndex;
    uint64_t renderedFrameCount;
    double hostTimestamp;
    bool isPlaying;
} SoundtimeAudioCoreClockSample;

typedef struct SoundtimeAudioCoreMeterSample {
    uint64_t startFrameIndex;
    uint64_t frameCount;
    uint64_t renderedFrameCount;
    double hostTimestamp;
    bool isPlaying;
    float leftRMS;
    float rightRMS;
    float leftPeak;
    float rightPeak;
    float leftClipPeak;
    float rightClipPeak;
} SoundtimeAudioCoreMeterSample;

typedef struct SoundtimeAudioCoreTrackMeterPacketHeader {
    uint64_t graphRevision;
    uint64_t sequence;
    uint64_t renderedFrameCount;
    double hostTimestamp;
    uint32_t trackCount;
} SoundtimeAudioCoreTrackMeterPacketHeader;

typedef struct SoundtimeAudioCoreTrackMeterLevel {
    uint32_t runtimeTrackSlot;
    uint32_t channelCount;
    float leftRMS;
    float rightRMS;
    float leftPeak;
    float rightPeak;
} SoundtimeAudioCoreTrackMeterLevel;

typedef struct SoundtimeAudioCoreTrackConfig {
    const SoundtimeAudioCoreSource* source;
    float gain;
} SoundtimeAudioCoreTrackConfig;

typedef struct SoundtimeAudioCoreSegmentConfig {
    uint64_t outputStartFrame;
    uint64_t sourceStartFrame;
    uint64_t frameCount;
    double sourceFrameScale;
    float gainStart;
    float gainEnd;
} SoundtimeAudioCoreSegmentConfig;

typedef struct SoundtimeAudioCoreAutomationPointConfig {
    uint64_t frame;
    float value;
    float curveToNext;
} SoundtimeAudioCoreAutomationPointConfig;

typedef struct SoundtimeAudioCoreSegmentedTrackConfig {
    const SoundtimeAudioCoreSource* source;
    const SoundtimeAudioCoreSegmentConfig* segments;
    uint32_t segmentCount;
    const SoundtimeAudioCoreAutomationPointConfig* volumeAutomationPoints;
    uint32_t volumeAutomationPointCount;
    const SoundtimeAudioCoreAutomationPointConfig* panAutomationPoints;
    uint32_t panAutomationPointCount;
    const SoundtimeAudioCoreAutomationPointConfig* muteAutomationPoints;
    uint32_t muteAutomationPointCount;
    float gain;
    float pan;
} SoundtimeAudioCoreSegmentedTrackConfig;

SoundtimeAudioCoreEngine* soundtime_audio_core_create(void);
void soundtime_audio_core_destroy(SoundtimeAudioCoreEngine* engine);
SoundtimeAudioCoreSource* soundtime_audio_core_source_create_planar(
    const float* const* channels,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
);
SoundtimeAudioCoreSource* soundtime_audio_core_source_create_wav_bytes(
    const uint8_t* bytes,
    uint64_t byteCount,
    uint64_t dataOffset,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate,
    uint32_t blockAlign,
    uint16_t formatTag,
    uint16_t bitsPerSample
);
void soundtime_audio_core_source_destroy(SoundtimeAudioCoreSource* source);
void soundtime_audio_core_reset(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_set_detailed_timing_enabled(
    SoundtimeAudioCoreEngine* engine,
    bool isEnabled
);
void soundtime_audio_core_set_source_info(
    SoundtimeAudioCoreEngine* engine,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
);
bool soundtime_audio_core_set_interleaved_source(
    SoundtimeAudioCoreEngine* engine,
    const float* samples,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
);
bool soundtime_audio_core_set_planar_source(
    SoundtimeAudioCoreEngine* engine,
    const float* const* channels,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
);
bool soundtime_audio_core_set_prepared_source(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreSource* source
);
bool soundtime_audio_core_set_prepared_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreTrackConfig* tracks,
    uint32_t trackCount
);
bool soundtime_audio_core_update_prepared_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreTrackConfig* tracks,
    uint32_t trackCount
);
bool soundtime_audio_core_set_prepared_segmented_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreSegmentedTrackConfig* tracks,
    uint32_t trackCount
);
bool soundtime_audio_core_set_prepared_segmented_tracks_at_sample_rate(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreSegmentedTrackConfig* tracks,
    uint32_t trackCount,
    double sampleRate
);
bool soundtime_audio_core_update_prepared_segmented_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreSegmentedTrackConfig* tracks,
    uint32_t trackCount
);
void soundtime_audio_core_play(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_pause(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_pause_at(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex);
void soundtime_audio_core_seek(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex);
void soundtime_audio_core_seek_exactly(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex);
void soundtime_audio_core_set_gain(SoundtimeAudioCoreEngine* engine, float gain);
bool soundtime_audio_core_set_track_pan(
    SoundtimeAudioCoreEngine* engine,
    uint32_t trackIndex,
    float pan
);
void soundtime_audio_core_set_transport_ramp_duration(
    SoundtimeAudioCoreEngine* engine,
    double durationSeconds
);
void soundtime_audio_core_set_track_gain_ramp_duration(
    SoundtimeAudioCoreEngine* engine,
    double durationSeconds
);
SoundtimeAudioCoreSnapshot soundtime_audio_core_snapshot(const SoundtimeAudioCoreEngine* engine);
bool soundtime_audio_core_pop_clock_sample(
    SoundtimeAudioCoreEngine* engine,
    SoundtimeAudioCoreClockSample* sample
);
bool soundtime_audio_core_pop_meter_sample(
    SoundtimeAudioCoreEngine* engine,
    SoundtimeAudioCoreMeterSample* sample
);
void soundtime_audio_core_set_track_metering_enabled(
    SoundtimeAudioCoreEngine* engine,
    bool isEnabled
);
uint64_t soundtime_audio_core_current_graph_revision(
    const SoundtimeAudioCoreEngine* engine
);
bool soundtime_audio_core_pop_track_meter_packet(
    SoundtimeAudioCoreEngine* engine,
    SoundtimeAudioCoreTrackMeterPacketHeader* header,
    SoundtimeAudioCoreTrackMeterLevel* levels,
    uint32_t levelCapacity
);
uint64_t soundtime_audio_core_dropped_track_meter_packet_count(
    const SoundtimeAudioCoreEngine* engine
);
uint64_t soundtime_audio_core_track_meter_work_nanoseconds(
    const SoundtimeAudioCoreEngine* engine
);
void soundtime_audio_core_render_silence(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount
);
void soundtime_audio_core_render_silence_at_host_time(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount,
    double hostTimestamp
);
void soundtime_audio_core_render(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount
);
void soundtime_audio_core_render_at_host_time(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount,
    double hostTimestamp
);
bool soundtime_audio_core_render_offline(
    SoundtimeAudioCoreEngine* engine,
    uint64_t startFrameIndex,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount
);

SoundtimeAudioCoreRecordingRing* soundtime_audio_core_recording_ring_create(
    uint32_t channelCount,
    uint64_t frameCapacity,
    double sampleRate
);
void soundtime_audio_core_recording_ring_destroy(SoundtimeAudioCoreRecordingRing* ring);
void soundtime_audio_core_recording_ring_reset(SoundtimeAudioCoreRecordingRing* ring);
uint32_t soundtime_audio_core_recording_ring_push_planar(
    SoundtimeAudioCoreRecordingRing* ring,
    const float* const* channels,
    uint32_t channelCount,
    uint32_t frameCount,
    double hostTimestamp
);
uint32_t soundtime_audio_core_recording_ring_pop_planar(
    SoundtimeAudioCoreRecordingRing* ring,
    float* const* channels,
    uint32_t channelCount,
    uint32_t maxFrameCount,
    double* hostTimestamp
);
uint64_t soundtime_audio_core_recording_ring_available_frame_count(
    const SoundtimeAudioCoreRecordingRing* ring
);
uint64_t soundtime_audio_core_recording_ring_dropped_frame_count(
    const SoundtimeAudioCoreRecordingRing* ring
);
uint32_t soundtime_audio_core_recording_ring_channel_count(
    const SoundtimeAudioCoreRecordingRing* ring
);
double soundtime_audio_core_recording_ring_sample_rate(
    const SoundtimeAudioCoreRecordingRing* ring
);

#ifdef __cplusplus
}
#endif

#endif
