#include "SoundtimeAudioCore.h"

#include <algorithm>
#include <atomic>
#include <cstdint>

struct SoundtimeAudioCoreEngine {
    std::atomic<uint64_t> frameIndex{0};
    std::atomic<uint64_t> frameCount{0};
    std::atomic<uint32_t> channelCount{0};
    std::atomic<double> sampleRate{0};
    std::atomic<bool> isPlaying{false};
    std::atomic<uint64_t> underrunCount{0};
    std::atomic<float> gain{1};
};

SoundtimeAudioCoreEngine* soundtime_audio_core_create(void) {
    return new SoundtimeAudioCoreEngine();
}

void soundtime_audio_core_destroy(SoundtimeAudioCoreEngine* engine) {
    delete engine;
}

void soundtime_audio_core_reset(SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return;
    }

    engine->frameIndex.store(0, std::memory_order_release);
    engine->frameCount.store(0, std::memory_order_release);
    engine->channelCount.store(0, std::memory_order_release);
    engine->sampleRate.store(0, std::memory_order_release);
    engine->isPlaying.store(false, std::memory_order_release);
    engine->underrunCount.store(0, std::memory_order_release);
    engine->gain.store(1, std::memory_order_release);
}

void soundtime_audio_core_set_source_info(
    SoundtimeAudioCoreEngine* engine,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
) {
    if (engine == nullptr) {
        return;
    }

    engine->frameIndex.store(0, std::memory_order_release);
    engine->frameCount.store(frameCount, std::memory_order_release);
    engine->channelCount.store(channelCount, std::memory_order_release);
    engine->sampleRate.store(sampleRate, std::memory_order_release);
    engine->isPlaying.store(false, std::memory_order_release);
    engine->underrunCount.store(0, std::memory_order_release);
}

void soundtime_audio_core_play(SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return;
    }

    const auto frameCount = engine->frameCount.load(std::memory_order_acquire);
    auto frameIndex = engine->frameIndex.load(std::memory_order_acquire);
    if (frameCount > 0 && frameIndex >= frameCount) {
        frameIndex = 0;
        engine->frameIndex.store(0, std::memory_order_release);
    }

    engine->isPlaying.store(frameCount > 0, std::memory_order_release);
}

void soundtime_audio_core_pause(SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return;
    }

    engine->isPlaying.store(false, std::memory_order_release);
}

void soundtime_audio_core_seek(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex) {
    if (engine == nullptr) {
        return;
    }

    const auto frameCount = engine->frameCount.load(std::memory_order_acquire);
    engine->frameIndex.store(std::min(frameIndex, frameCount), std::memory_order_release);
}

void soundtime_audio_core_set_gain(SoundtimeAudioCoreEngine* engine, float gain) {
    if (engine == nullptr) {
        return;
    }

    engine->gain.store(std::max(gain, 0.0f), std::memory_order_release);
}

SoundtimeAudioCoreSnapshot soundtime_audio_core_snapshot(const SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return SoundtimeAudioCoreSnapshot{};
    }

    return SoundtimeAudioCoreSnapshot{
        .frameIndex = engine->frameIndex.load(std::memory_order_acquire),
        .frameCount = engine->frameCount.load(std::memory_order_acquire),
        .sampleRate = engine->sampleRate.load(std::memory_order_acquire),
        .isPlaying = engine->isPlaying.load(std::memory_order_acquire),
        .underrunCount = engine->underrunCount.load(std::memory_order_acquire),
    };
}

void soundtime_audio_core_render_silence(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount
) {
    if (outputs == nullptr) {
        if (engine != nullptr) {
            engine->underrunCount.fetch_add(1, std::memory_order_acq_rel);
        }
        return;
    }

    for (uint32_t channelIndex = 0; channelIndex < channelCount; channelIndex++) {
        auto* output = outputs[channelIndex];
        if (output == nullptr) {
            continue;
        }

        std::fill(output, output + frameCount, 0.0f);
    }

    if (engine == nullptr || !engine->isPlaying.load(std::memory_order_acquire)) {
        return;
    }

    const auto sourceFrameCount = engine->frameCount.load(std::memory_order_acquire);
    auto nextFrameIndex = engine->frameIndex.load(std::memory_order_acquire);
    nextFrameIndex = std::min<uint64_t>(nextFrameIndex + frameCount, sourceFrameCount);
    engine->frameIndex.store(nextFrameIndex, std::memory_order_release);
    if (nextFrameIndex >= sourceFrameCount) {
        engine->isPlaying.store(false, std::memory_order_release);
    }
}
