#include "SoundtimeAudioCore.h"

#include "third_party/ez/ez.hpp"

#include <algorithm>
#include <atomic>
#include <cstdint>

namespace {

struct EngineConfig {
    uint64_t frameCount = 0;
    uint32_t channelCount = 0;
    double sampleRate = 0;
    float gain = 1;
};

} // namespace

struct SoundtimeAudioCoreEngine {
    std::atomic<uint64_t> frameIndex{0};
    std::atomic<bool> isPlaying{false};
    std::atomic<uint64_t> underrunCount{0};
    ez::sync<EngineConfig> config;
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
    engine->isPlaying.store(false, std::memory_order_release);
    engine->underrunCount.store(0, std::memory_order_release);
    engine->config.set_publish(ez::nort, EngineConfig{});
    engine->config.gc(ez::gc);
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
    engine->isPlaying.store(false, std::memory_order_release);
    engine->underrunCount.store(0, std::memory_order_release);
    engine->config.update_publish(ez::nort, [=](EngineConfig config) {
        config.frameCount = frameCount;
        config.channelCount = channelCount;
        config.sampleRate = sampleRate;
        return config;
    });
    engine->config.gc(ez::gc);
}

void soundtime_audio_core_play(SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return;
    }

    const auto config = engine->config.read(ez::nort);
    const auto frameCount = config.frameCount;
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

    const auto config = engine->config.read(ez::nort);
    const auto frameCount = config.frameCount;
    engine->frameIndex.store(std::min(frameIndex, frameCount), std::memory_order_release);
}

void soundtime_audio_core_set_gain(SoundtimeAudioCoreEngine* engine, float gain) {
    if (engine == nullptr) {
        return;
    }

    engine->config.update_publish(ez::nort, [=](EngineConfig config) {
        config.gain = std::max(gain, 0.0f);
        return config;
    });
    engine->config.gc(ez::gc);
}

SoundtimeAudioCoreSnapshot soundtime_audio_core_snapshot(const SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return SoundtimeAudioCoreSnapshot{};
    }

    const auto config = engine->config.read(ez::nort);
    return SoundtimeAudioCoreSnapshot{
        .frameIndex = engine->frameIndex.load(std::memory_order_acquire),
        .frameCount = config.frameCount,
        .sampleRate = config.sampleRate,
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

    const auto config = engine->config.read(ez::audio);
    const auto sourceFrameCount = config->frameCount;
    auto nextFrameIndex = engine->frameIndex.load(std::memory_order_acquire);
    nextFrameIndex = std::min<uint64_t>(nextFrameIndex + frameCount, sourceFrameCount);
    engine->frameIndex.store(nextFrameIndex, std::memory_order_release);
    if (nextFrameIndex >= sourceFrameCount) {
        engine->isPlaying.store(false, std::memory_order_release);
    }
}
