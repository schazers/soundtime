#include "SoundtimeAudioCore.h"

#include "third_party/ez/ez.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

namespace {

struct AudioSource {
    std::vector<float> interleavedSamples;
    uint64_t frameCount = 0;
    uint32_t channelCount = 0;
    double sampleRate = 0;
};

struct EngineConfig {
    uint64_t frameCount = 0;
    uint32_t channelCount = 0;
    double sampleRate = 0;
    float gain = 1;
    double transportRampDurationSeconds = 0.018;
    std::shared_ptr<const AudioSource> source;
};

enum class EngineCommandType : uint8_t {
    play,
    pause,
    seek,
};

struct EngineCommand {
    EngineCommandType type = EngineCommandType::pause;
    uint64_t frameIndex = 0;
};

template <typename T, size_t Capacity>
class SPSCQueue {
public:
    static_assert(Capacity > 1);

    [[nodiscard]] bool push(const T& value) {
        const auto writeIndex = writeIndex_.load(std::memory_order_relaxed);
        const auto nextWriteIndex = increment(writeIndex);
        if (nextWriteIndex == readIndex_.load(std::memory_order_acquire)) {
            return false;
        }

        storage_[writeIndex] = value;
        writeIndex_.store(nextWriteIndex, std::memory_order_release);
        return true;
    }

    [[nodiscard]] bool pop(T& value) {
        const auto readIndex = readIndex_.load(std::memory_order_relaxed);
        if (readIndex == writeIndex_.load(std::memory_order_acquire)) {
            return false;
        }

        value = storage_[readIndex];
        readIndex_.store(increment(readIndex), std::memory_order_release);
        return true;
    }

    void clear() {
        readIndex_.store(writeIndex_.load(std::memory_order_acquire), std::memory_order_release);
    }

private:
    static constexpr size_t increment(size_t index) {
        return (index + 1) % Capacity;
    }

    std::array<T, Capacity> storage_{};
    std::atomic<size_t> writeIndex_{0};
    std::atomic<size_t> readIndex_{0};
};

} // namespace

struct SoundtimeAudioCoreEngine {
    std::atomic<uint64_t> frameIndex{0};
    std::atomic<uint64_t> renderedFrameCount{0};
    std::atomic<double> hostTimestamp{0};
    std::atomic<bool> isPlaying{false};
    std::atomic<uint64_t> underrunCount{0};
    std::atomic<uint64_t> droppedCommandCount{0};
    ez::sync<EngineConfig> config;
    SPSCQueue<EngineCommand, 256> commandQueue;
    float transportGain = 1;
    float transportGainTarget = 1;
    float transportGainStep = 0;
    uint64_t transportRampFramesRemaining = 0;
    bool stopWhenTransportRampCompletes = false;
};

namespace {

void submit_command(SoundtimeAudioCoreEngine& engine, EngineCommand command) {
    if (!engine.commandQueue.push(command)) {
        engine.droppedCommandCount.fetch_add(1, std::memory_order_acq_rel);
    }
}

void begin_transport_ramp(
    SoundtimeAudioCoreEngine& engine,
    float targetGain,
    const EngineConfig& config,
    bool stopWhenComplete
) {
    const auto rampFrames = config.transportRampDurationSeconds > 0 && config.sampleRate > 0 ?
        static_cast<uint64_t>(config.transportRampDurationSeconds * config.sampleRate + 0.5) :
        uint64_t{0};

    engine.transportGainTarget = std::max(targetGain, 0.0f);
    engine.stopWhenTransportRampCompletes = stopWhenComplete;
    if (rampFrames == 0) {
        engine.transportGain = engine.transportGainTarget;
        engine.transportGainStep = 0;
        engine.transportRampFramesRemaining = 0;
        if (stopWhenComplete) {
            engine.isPlaying.store(false, std::memory_order_release);
            engine.stopWhenTransportRampCompletes = false;
        }
        return;
    }

    engine.transportRampFramesRemaining = rampFrames;
    engine.transportGainStep = (engine.transportGainTarget - engine.transportGain) /
        static_cast<float>(rampFrames);
}

float next_transport_gain(SoundtimeAudioCoreEngine& engine) {
    if (engine.transportRampFramesRemaining == 0) {
        return engine.transportGain;
    }

    engine.transportGain += engine.transportGainStep;
    engine.transportRampFramesRemaining--;
    if (engine.transportRampFramesRemaining == 0) {
        engine.transportGain = engine.transportGainTarget;
        engine.transportGainStep = 0;
        if (engine.stopWhenTransportRampCompletes) {
            engine.isPlaying.store(false, std::memory_order_release);
            engine.stopWhenTransportRampCompletes = false;
        }
    }

    return engine.transportGain;
}

void process_commands(SoundtimeAudioCoreEngine& engine, const EngineConfig& config) {
    auto command = EngineCommand{};
    while (engine.commandQueue.pop(command)) {
        switch (command.type) {
        case EngineCommandType::play: {
            auto frameIndex = engine.frameIndex.load(std::memory_order_acquire);
            if (config.frameCount > 0 && frameIndex >= config.frameCount) {
                frameIndex = 0;
                engine.frameIndex.store(0, std::memory_order_release);
            }
            engine.isPlaying.store(config.frameCount > 0, std::memory_order_release);
            if (config.frameCount > 0) {
                engine.transportGain = 0;
                begin_transport_ramp(engine, 1, config, false);
            }
            break;
        }
        case EngineCommandType::pause:
            begin_transport_ramp(engine, 0, config, true);
            break;
        case EngineCommandType::seek:
            engine.frameIndex.store(
                std::min(command.frameIndex, config.frameCount),
                std::memory_order_release
            );
            break;
        }
    }
}

} // namespace

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
    engine->renderedFrameCount.store(0, std::memory_order_release);
    engine->hostTimestamp.store(0, std::memory_order_release);
    engine->isPlaying.store(false, std::memory_order_release);
    engine->underrunCount.store(0, std::memory_order_release);
    engine->droppedCommandCount.store(0, std::memory_order_release);
    engine->transportGain = 1;
    engine->transportGainTarget = 1;
    engine->transportGainStep = 0;
    engine->transportRampFramesRemaining = 0;
    engine->stopWhenTransportRampCompletes = false;
    engine->commandQueue.clear();
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
    engine->renderedFrameCount.store(0, std::memory_order_release);
    engine->hostTimestamp.store(0, std::memory_order_release);
    engine->isPlaying.store(false, std::memory_order_release);
    engine->underrunCount.store(0, std::memory_order_release);
    engine->droppedCommandCount.store(0, std::memory_order_release);
    engine->transportGain = 1;
    engine->transportGainTarget = 1;
    engine->transportGainStep = 0;
    engine->transportRampFramesRemaining = 0;
    engine->stopWhenTransportRampCompletes = false;
    engine->commandQueue.clear();
    engine->config.update_publish(ez::nort, [=](EngineConfig config) {
        config.frameCount = frameCount;
        config.channelCount = channelCount;
        config.sampleRate = sampleRate;
        return config;
    });
    engine->config.gc(ez::gc);
}

bool soundtime_audio_core_set_interleaved_source(
    SoundtimeAudioCoreEngine* engine,
    const float* samples,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
) {
    if (engine == nullptr || channelCount == 0) {
        return false;
    }

    const auto sampleCount = frameCount * channelCount;
    if (sampleCount > 0 && samples == nullptr) {
        return false;
    }

    auto source = std::make_shared<AudioSource>();
    source->frameCount = frameCount;
    source->channelCount = channelCount;
    source->sampleRate = sampleRate;
    if (sampleCount > 0) {
        source->interleavedSamples.assign(samples, samples + sampleCount);
    }

    engine->frameIndex.store(0, std::memory_order_release);
    engine->renderedFrameCount.store(0, std::memory_order_release);
    engine->hostTimestamp.store(0, std::memory_order_release);
    engine->isPlaying.store(false, std::memory_order_release);
    engine->underrunCount.store(0, std::memory_order_release);
    engine->droppedCommandCount.store(0, std::memory_order_release);
    engine->transportGain = 1;
    engine->transportGainTarget = 1;
    engine->transportGainStep = 0;
    engine->transportRampFramesRemaining = 0;
    engine->stopWhenTransportRampCompletes = false;
    engine->commandQueue.clear();
    engine->config.update_publish(ez::nort, [=](EngineConfig config) {
        config.frameCount = frameCount;
        config.channelCount = channelCount;
        config.sampleRate = sampleRate;
        config.source = source;
        return config;
    });
    engine->config.gc(ez::gc);
    return true;
}

void soundtime_audio_core_play(SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return;
    }

    submit_command(*engine, EngineCommand{.type = EngineCommandType::play});
}

void soundtime_audio_core_pause(SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return;
    }

    submit_command(*engine, EngineCommand{.type = EngineCommandType::pause});
}

void soundtime_audio_core_seek(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex) {
    if (engine == nullptr) {
        return;
    }

    submit_command(*engine, EngineCommand{
        .type = EngineCommandType::seek,
        .frameIndex = frameIndex,
    });
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

void soundtime_audio_core_set_transport_ramp_duration(
    SoundtimeAudioCoreEngine* engine,
    double durationSeconds
) {
    if (engine == nullptr) {
        return;
    }

    engine->config.update_publish(ez::nort, [=](EngineConfig config) {
        config.transportRampDurationSeconds = std::max(durationSeconds, 0.0);
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
        .hostTimestamp = engine->hostTimestamp.load(std::memory_order_acquire),
        .isPlaying = engine->isPlaying.load(std::memory_order_acquire),
        .renderedFrameCount = engine->renderedFrameCount.load(std::memory_order_acquire),
        .underrunCount = engine->underrunCount.load(std::memory_order_acquire),
        .droppedCommandCount = engine->droppedCommandCount.load(std::memory_order_acquire),
    };
}

void soundtime_audio_core_render_silence(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount
) {
    soundtime_audio_core_render_silence_at_host_time(
        engine,
        outputs,
        channelCount,
        frameCount,
        0
    );
}

void soundtime_audio_core_render_silence_at_host_time(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount,
    double hostTimestamp
) {
    soundtime_audio_core_render_at_host_time(
        engine,
        outputs,
        channelCount,
        frameCount,
        hostTimestamp
    );
}

void soundtime_audio_core_render(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount
) {
    soundtime_audio_core_render_at_host_time(
        engine,
        outputs,
        channelCount,
        frameCount,
        0
    );
}

void soundtime_audio_core_render_at_host_time(
    SoundtimeAudioCoreEngine* engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount,
    double hostTimestamp
) {
    if (outputs == nullptr) {
        if (engine != nullptr) {
            engine->underrunCount.fetch_add(1, std::memory_order_acq_rel);
        }
        return;
    }

    auto config = ez::immutable<EngineConfig>{};
    if (engine != nullptr) {
        engine->hostTimestamp.store(hostTimestamp, std::memory_order_release);
        engine->renderedFrameCount.fetch_add(frameCount, std::memory_order_acq_rel);
        config = engine->config.read(ez::audio);
        process_commands(*engine, *config);
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

    const auto sourceFrameCount = config->frameCount;
    const auto currentFrameIndex = engine->frameIndex.load(std::memory_order_acquire);
    const auto renderableFrameCount = sourceFrameCount > currentFrameIndex ?
        std::min<uint64_t>(frameCount, sourceFrameCount - currentFrameIndex) :
        0;
    uint64_t advancedFrameCount = 0;
    if (const auto& source = config->source) {
        const auto sourceChannelCount = source->channelCount;
        for (uint64_t frameOffset = 0; frameOffset < renderableFrameCount; frameOffset++) {
            const auto outputGain = config->gain * next_transport_gain(*engine);
            const auto sourceFrameIndex = currentFrameIndex + frameOffset;
            for (uint32_t outputChannel = 0; outputChannel < channelCount; outputChannel++) {
                auto* output = outputs[outputChannel];
                if (output == nullptr) {
                    continue;
                }

                const auto sourceChannel = sourceChannelCount == 1 ?
                    uint32_t{0} :
                    outputChannel;
                if (sourceChannel >= sourceChannelCount) {
                    continue;
                }

                const auto sampleIndex = sourceFrameIndex * sourceChannelCount + sourceChannel;
                output[frameOffset] = source->interleavedSamples[sampleIndex] * outputGain;
            }
            advancedFrameCount++;
            if (!engine->isPlaying.load(std::memory_order_acquire)) {
                break;
            }
        }
    } else {
        for (uint64_t frameOffset = 0; frameOffset < renderableFrameCount; frameOffset++) {
            next_transport_gain(*engine);
            advancedFrameCount++;
            if (!engine->isPlaying.load(std::memory_order_acquire)) {
                break;
            }
        }
    }

    auto nextFrameIndex = std::min<uint64_t>(currentFrameIndex + advancedFrameCount, sourceFrameCount);
    engine->frameIndex.store(nextFrameIndex, std::memory_order_release);
    if (nextFrameIndex >= sourceFrameCount) {
        engine->isPlaying.store(false, std::memory_order_release);
    }
}
