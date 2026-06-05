#ifndef SOUNDTIME_AUDIO_CORE_H
#define SOUNDTIME_AUDIO_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SoundtimeAudioCoreEngine SoundtimeAudioCoreEngine;

typedef struct SoundtimeAudioCoreSnapshot {
    uint64_t frameIndex;
    uint64_t frameCount;
    double sampleRate;
    bool isPlaying;
    uint64_t underrunCount;
    uint64_t droppedCommandCount;
} SoundtimeAudioCoreSnapshot;

SoundtimeAudioCoreEngine* soundtime_audio_core_create(void);
void soundtime_audio_core_destroy(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_reset(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_set_source_info(
    SoundtimeAudioCoreEngine* engine,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
);
void soundtime_audio_core_play(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_pause(SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_seek(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex);
void soundtime_audio_core_set_gain(SoundtimeAudioCoreEngine* engine, float gain);
SoundtimeAudioCoreSnapshot soundtime_audio_core_snapshot(const SoundtimeAudioCoreEngine* engine);
void soundtime_audio_core_render_silence(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount
);

#ifdef __cplusplus
}
#endif

#endif
