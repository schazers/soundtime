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

typedef struct SoundtimeAudioCoreSegmentedTrackConfig {
    const SoundtimeAudioCoreSource* source;
    const SoundtimeAudioCoreSegmentConfig* segments;
    uint32_t segmentCount;
    float gain;
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
bool soundtime_audio_core_update_prepared_segmented_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreSegmentedTrackConfig* tracks,
    uint32_t trackCount
);
void soundtime_audio_core_play(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_pause(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_pause_at(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex);
void soundtime_audio_core_seek(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex);
void soundtime_audio_core_set_gain(SoundtimeAudioCoreEngine* engine, float gain);
void soundtime_audio_core_set_transport_ramp_duration(
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
