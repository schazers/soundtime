#include "SoundtimeAudioCore.h"

#include "third_party/ez/ez.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

namespace {

struct AudioSource {
    std::vector<float> interleavedSamples;
    uint64_t frameCount = 0;
    uint32_t channelCount = 0;
    double sampleRate = 0;
};

struct RenderSegment {
    uint64_t outputStartFrame = 0;
    uint64_t sourceStartFrame = 0;
    uint64_t frameCount = 0;
    float gain = 1;
};

struct RenderTrack {
    std::shared_ptr<const AudioSource> source;
    std::vector<RenderSegment> segments;
    float gain = 1;
};

struct RenderGraph {
    uint64_t frameCount = 0;
    uint32_t channelCount = 0;
    double sampleRate = 0;
    std::vector<RenderTrack> tracks;
};

struct EngineConfig {
    uint64_t frameCount = 0;
    uint32_t channelCount = 0;
    double sampleRate = 0;
    float gain = 1;
    double transportRampDurationSeconds = 0.018;
    std::shared_ptr<const AudioSource> source;
    std::shared_ptr<const RenderGraph> graph;
};

enum class EngineCommandType : uint8_t {
    play,
    pause,
    pauseAt,
    seek,
};

struct EngineCommand {
    EngineCommandType type = EngineCommandType::pause;
    uint64_t frameIndex = 0;
};

struct ClockSample {
    uint64_t frameIndex = 0;
    uint64_t renderedFrameCount = 0;
    double hostTimestamp = 0;
    bool isPlaying = false;
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
    SPSCQueue<ClockSample, 1024> clockSamples;
    float transportGain = 1;
    float transportGainTarget = 1;
    float transportGainStep = 0;
    uint64_t transportRampFramesRemaining = 0;
    bool stopWhenTransportRampCompletes = false;
    uint64_t transportPauseFrameIndex = 0;
    bool hasTransportPauseFrameIndex = false;
};

struct SoundtimeAudioCoreSource {
    std::shared_ptr<const AudioSource> source;
};

namespace {

void submit_command(SoundtimeAudioCoreEngine& engine, EngineCommand command) {
    if (!engine.commandQueue.push(command)) {
        engine.droppedCommandCount.fetch_add(1, std::memory_order_acq_rel);
    }
}

void complete_transport_stop(SoundtimeAudioCoreEngine& engine) {
    engine.isPlaying.store(false, std::memory_order_release);
    if (engine.hasTransportPauseFrameIndex) {
        engine.frameIndex.store(engine.transportPauseFrameIndex, std::memory_order_release);
        engine.hasTransportPauseFrameIndex = false;
    }
    engine.stopWhenTransportRampCompletes = false;
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
            complete_transport_stop(engine);
        }
        return;
    }

    engine.transportRampFramesRemaining = rampFrames;
    engine.transportGainStep = (engine.transportGainTarget - engine.transportGain) /
        static_cast<float>(rampFrames);
}

float next_transport_gain(SoundtimeAudioCoreEngine& engine, bool& completedTransportStop) {
    if (engine.transportRampFramesRemaining == 0) {
        return engine.transportGain;
    }

    engine.transportGain += engine.transportGainStep;
    engine.transportRampFramesRemaining--;
    if (engine.transportRampFramesRemaining == 0) {
        engine.transportGain = engine.transportGainTarget;
        engine.transportGainStep = 0;
        if (engine.stopWhenTransportRampCompletes) {
            complete_transport_stop(engine);
            completedTransportStop = true;
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
            engine.hasTransportPauseFrameIndex = false;
            engine.isPlaying.store(config.frameCount > 0, std::memory_order_release);
            if (config.frameCount > 0) {
                engine.transportGain = 0;
                begin_transport_ramp(engine, 1, config, false);
            }
            break;
        }
        case EngineCommandType::pause:
            engine.transportPauseFrameIndex = std::min(
                engine.frameIndex.load(std::memory_order_acquire),
                config.frameCount
            );
            engine.hasTransportPauseFrameIndex = true;
            begin_transport_ramp(engine, 0, config, true);
            break;
        case EngineCommandType::pauseAt:
            engine.transportPauseFrameIndex = std::min(command.frameIndex, config.frameCount);
            engine.hasTransportPauseFrameIndex = true;
            engine.frameIndex.store(engine.transportPauseFrameIndex, std::memory_order_release);
            begin_transport_ramp(engine, 0, config, true);
            break;
        case EngineCommandType::seek:
            engine.hasTransportPauseFrameIndex = false;
            engine.frameIndex.store(
                std::min(command.frameIndex, config.frameCount),
                std::memory_order_release
            );
            break;
        }
    }
}

void reset_engine_runtime(SoundtimeAudioCoreEngine& engine) {
    engine.frameIndex.store(0, std::memory_order_release);
    engine.renderedFrameCount.store(0, std::memory_order_release);
    engine.hostTimestamp.store(0, std::memory_order_release);
    engine.isPlaying.store(false, std::memory_order_release);
    engine.underrunCount.store(0, std::memory_order_release);
    engine.droppedCommandCount.store(0, std::memory_order_release);
    engine.transportGain = 1;
    engine.transportGainTarget = 1;
    engine.transportGainStep = 0;
    engine.transportRampFramesRemaining = 0;
    engine.stopWhenTransportRampCompletes = false;
    engine.transportPauseFrameIndex = 0;
    engine.hasTransportPauseFrameIndex = false;
    engine.commandQueue.clear();
    engine.clockSamples.clear();
}

void publish_graph(
    SoundtimeAudioCoreEngine& engine,
    std::shared_ptr<const RenderGraph> graph,
    bool resetRuntime
) {
    if (resetRuntime) {
        reset_engine_runtime(engine);
    }
    engine.config.update_publish(ez::nort, [=](EngineConfig config) {
        config.frameCount = graph->frameCount;
        config.channelCount = graph->channelCount;
        config.sampleRate = graph->sampleRate;
        config.source = nullptr;
        config.graph = graph;
        return config;
    });
    engine.config.gc(ez::gc);
}

std::shared_ptr<RenderGraph> make_graph_from_track_configs(
    const SoundtimeAudioCoreTrackConfig* tracks,
    uint32_t trackCount
) {
    if (tracks == nullptr || trackCount == 0) {
        return nullptr;
    }

    const auto* firstSource = tracks[0].source;
    if (firstSource == nullptr || !firstSource->source) {
        return nullptr;
    }

    const auto sampleRate = firstSource->source->sampleRate;
    if (sampleRate <= 0) {
        return nullptr;
    }

    auto graph = std::make_shared<RenderGraph>();
    graph->sampleRate = sampleRate;

    for (uint32_t trackIndex = 0; trackIndex < trackCount; trackIndex++) {
        const auto& trackConfig = tracks[trackIndex];
        if (trackConfig.source == nullptr || !trackConfig.source->source) {
            return nullptr;
        }

        const auto source = trackConfig.source->source;
        if (source->sampleRate != sampleRate || source->channelCount == 0) {
            return nullptr;
        }

        graph->frameCount = std::max(graph->frameCount, source->frameCount);
        graph->channelCount = std::max(graph->channelCount, source->channelCount);

        auto track = RenderTrack{
            .source = source,
            .segments = {},
            .gain = std::max(trackConfig.gain, 0.0f),
        };
        if (source->frameCount > 0) {
            track.segments.push_back(RenderSegment{
                .outputStartFrame = 0,
                .sourceStartFrame = 0,
                .frameCount = source->frameCount,
                .gain = 1,
            });
        }
        graph->tracks.push_back(std::move(track));
    }

    if (graph->channelCount == 0 || graph->frameCount == 0) {
        return nullptr;
    }

    return graph;
}

void publish_source(SoundtimeAudioCoreEngine& engine, std::shared_ptr<const AudioSource> source) {
    auto graph = std::make_shared<RenderGraph>();
    graph->frameCount = source->frameCount;
    graph->channelCount = source->channelCount;
    graph->sampleRate = source->sampleRate;
    auto track = RenderTrack{
        .source = source,
        .segments = {},
        .gain = 1,
    };
    if (source->frameCount > 0) {
        track.segments.push_back(RenderSegment{
            .outputStartFrame = 0,
            .sourceStartFrame = 0,
            .frameCount = source->frameCount,
            .gain = 1,
        });
    }
    graph->tracks.push_back(std::move(track));

    publish_graph(engine, graph, true);
}

std::shared_ptr<AudioSource> make_planar_source(
    const float* const* channels,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
) {
    if (channelCount == 0) {
        return nullptr;
    }

    if (frameCount > 0 && channels == nullptr) {
        return nullptr;
    }

    auto source = std::make_shared<AudioSource>();
    source->frameCount = frameCount;
    source->channelCount = channelCount;
    source->sampleRate = sampleRate;
    source->interleavedSamples.resize(frameCount * channelCount);

    for (uint32_t channelIndex = 0; channelIndex < channelCount; channelIndex++) {
        const auto* channelSamples = channels[channelIndex];
        if (frameCount > 0 && channelSamples == nullptr) {
            return nullptr;
        }

        for (uint64_t frameIndex = 0; frameIndex < frameCount; frameIndex++) {
            source->interleavedSamples[frameIndex * channelCount + channelIndex] =
                channelSamples[frameIndex];
        }
    }

    return source;
}

void publish_clock_sample(SoundtimeAudioCoreEngine& engine) {
    static_cast<void>(engine.clockSamples.push(ClockSample{
        .frameIndex = engine.frameIndex.load(std::memory_order_acquire),
        .renderedFrameCount = engine.renderedFrameCount.load(std::memory_order_acquire),
        .hostTimestamp = engine.hostTimestamp.load(std::memory_order_acquire),
        .isPlaying = engine.isPlaying.load(std::memory_order_acquire),
    }));
}

} // namespace

SoundtimeAudioCoreEngine* soundtime_audio_core_create(void) {
    return new SoundtimeAudioCoreEngine();
}

void soundtime_audio_core_destroy(SoundtimeAudioCoreEngine* engine) {
    delete engine;
}

SoundtimeAudioCoreSource* soundtime_audio_core_source_create_planar(
    const float* const* channels,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
) {
    auto source = make_planar_source(channels, frameCount, channelCount, sampleRate);
    if (!source) {
        return nullptr;
    }

    return new SoundtimeAudioCoreSource{.source = source};
}

void soundtime_audio_core_source_destroy(SoundtimeAudioCoreSource* source) {
    delete source;
}

void soundtime_audio_core_reset(SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return;
    }

    reset_engine_runtime(*engine);
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

    reset_engine_runtime(*engine);
    engine->config.update_publish(ez::nort, [=](EngineConfig config) {
        config.frameCount = frameCount;
        config.channelCount = channelCount;
        config.sampleRate = sampleRate;
        config.source = nullptr;
        config.graph = nullptr;
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

    publish_source(*engine, source);
    return true;
}

bool soundtime_audio_core_set_planar_source(
    SoundtimeAudioCoreEngine* engine,
    const float* const* channels,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
) {
    if (engine == nullptr || channelCount == 0) {
        return false;
    }

    auto source = make_planar_source(channels, frameCount, channelCount, sampleRate);
    if (!source) {
        return false;
    }

    publish_source(*engine, source);
    return true;
}

bool soundtime_audio_core_set_prepared_source(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreSource* source
) {
    if (engine == nullptr || source == nullptr || !source->source) {
        return false;
    }

    publish_source(*engine, source->source);
    return true;
}

bool soundtime_audio_core_set_prepared_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreTrackConfig* tracks,
    uint32_t trackCount
) {
    if (engine == nullptr) {
        return false;
    }

    const auto graph = make_graph_from_track_configs(tracks, trackCount);
    if (!graph) {
        return false;
    }

    publish_graph(*engine, graph, true);
    return true;
}

bool soundtime_audio_core_update_prepared_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreTrackConfig* tracks,
    uint32_t trackCount
) {
    if (engine == nullptr) {
        return false;
    }

    const auto graph = make_graph_from_track_configs(tracks, trackCount);
    if (!graph) {
        return false;
    }

    publish_graph(*engine, graph, false);
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

void soundtime_audio_core_pause_at(SoundtimeAudioCoreEngine* engine, uint64_t frameIndex) {
    if (engine == nullptr) {
        return;
    }

    submit_command(*engine, EngineCommand{
        .type = EngineCommandType::pauseAt,
        .frameIndex = frameIndex,
    });
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

bool soundtime_audio_core_pop_clock_sample(
    SoundtimeAudioCoreEngine* engine,
    SoundtimeAudioCoreClockSample* sample
) {
    if (engine == nullptr || sample == nullptr) {
        return false;
    }

    auto clockSample = ClockSample{};
    if (!engine->clockSamples.pop(clockSample)) {
        return false;
    }

    sample->frameIndex = clockSample.frameIndex;
    sample->renderedFrameCount = clockSample.renderedFrameCount;
    sample->hostTimestamp = clockSample.hostTimestamp;
    sample->isPlaying = clockSample.isPlaying;
    return true;
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

    if (engine == nullptr) {
        return;
    }

    if (!engine->isPlaying.load(std::memory_order_acquire)) {
        publish_clock_sample(*engine);
        return;
    }

    const auto sourceFrameCount = config->frameCount;
    const auto currentFrameIndex = engine->frameIndex.load(std::memory_order_acquire);
    const auto renderableFrameCount = sourceFrameCount > currentFrameIndex ?
        std::min<uint64_t>(frameCount, sourceFrameCount - currentFrameIndex) :
        0;
    uint64_t advancedFrameCount = 0;
    bool completedTransportStop = false;
    if (const auto& graph = config->graph; graph && !graph->tracks.empty()) {
        for (uint64_t frameOffset = 0; frameOffset < renderableFrameCount; frameOffset++) {
            const auto transportGain = next_transport_gain(*engine, completedTransportStop);
            const auto outputFrameIndex = currentFrameIndex + frameOffset;
            const auto outputGainBase = config->gain * transportGain;

            advancedFrameCount++;
            for (const auto& track : graph->tracks) {
                const auto& source = track.source;
                if (!source || track.gain <= 0) {
                    continue;
                }

                for (const auto& segment : track.segments) {
                    if (
                        outputFrameIndex < segment.outputStartFrame ||
                        outputFrameIndex >= segment.outputStartFrame + segment.frameCount
                    ) {
                        continue;
                    }

                    const auto segmentFrameOffset = outputFrameIndex - segment.outputStartFrame;
                    const auto segmentSourceFrameIndex = segment.sourceStartFrame + segmentFrameOffset;
                    if (segmentSourceFrameIndex >= source->frameCount) {
                        continue;
                    }

                    const auto sourceChannelCount = source->channelCount;
                    const auto outputGain = outputGainBase * track.gain * segment.gain;
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

                        const auto sampleIndex = segmentSourceFrameIndex * sourceChannelCount + sourceChannel;
                        output[frameOffset] += source->interleavedSamples[sampleIndex] * outputGain;
                    }
                    break;
                }
            }
            if (!engine->isPlaying.load(std::memory_order_acquire)) {
                break;
            }
        }
    } else {
        for (uint64_t frameOffset = 0; frameOffset < renderableFrameCount; frameOffset++) {
            next_transport_gain(*engine, completedTransportStop);
            advancedFrameCount++;
            if (!engine->isPlaying.load(std::memory_order_acquire)) {
                break;
            }
        }
    }

    auto nextFrameIndex = std::min<uint64_t>(currentFrameIndex + advancedFrameCount, sourceFrameCount);
    if (completedTransportStop) {
        nextFrameIndex = engine->frameIndex.load(std::memory_order_acquire);
    } else {
        engine->frameIndex.store(nextFrameIndex, std::memory_order_release);
    }
    if (nextFrameIndex >= sourceFrameCount) {
        engine->isPlaying.store(false, std::memory_order_release);
    }
    publish_clock_sample(*engine);
}
