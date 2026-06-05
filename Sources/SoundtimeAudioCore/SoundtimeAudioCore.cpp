#include "SoundtimeAudioCore.h"

#include "third_party/ez/ez.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <utility>
#include <vector>

namespace {

struct AudioSource {
    enum class Storage {
        interleavedFloat,
        wavBytes,
    };

    Storage storage = Storage::interleavedFloat;
    std::vector<float> interleavedSamples;
    const uint8_t* wavBytes = nullptr;
    uint64_t wavByteCount = 0;
    uint64_t wavDataOffset = 0;
    uint32_t wavBlockAlign = 0;
    uint16_t wavFormatTag = 0;
    uint16_t wavBitsPerSample = 0;
    uint64_t frameCount = 0;
    uint32_t channelCount = 0;
    double sampleRate = 0;
};

struct RenderSegment {
    uint64_t outputStartFrame = 0;
    uint64_t sourceStartFrame = 0;
    uint64_t frameCount = 0;
    double sourceFrameScale = 1;
    bool usesExactSourceFrames = true;
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
    double trackGainRampDurationSeconds = 0.003;
    std::shared_ptr<const AudioSource> source;
    std::shared_ptr<const RenderGraph> graph;
};

struct TrackGainRamp {
    std::shared_ptr<const AudioSource> source;
    float currentGain = 0;
    float targetGain = 0;
    float gainStep = 0;
    uint64_t rampFramesRemaining = 0;
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

struct MeterSample {
    uint64_t startFrameIndex = 0;
    uint64_t frameCount = 0;
    uint64_t renderedFrameCount = 0;
    double hostTimestamp = 0;
    bool isPlaying = false;
    float leftRMS = 0;
    float rightRMS = 0;
    float leftPeak = 0;
    float rightPeak = 0;
    float leftClipPeak = 0;
    float rightClipPeak = 0;
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
    SoundtimeAudioCoreEngine() {
        trackGainRamps.reserve(64);
    }

    std::atomic<uint64_t> frameIndex{0};
    std::atomic<uint64_t> renderedFrameCount{0};
    std::atomic<double> hostTimestamp{0};
    std::atomic<bool> isPlaying{false};
    std::atomic<uint64_t> underrunCount{0};
    std::atomic<uint64_t> droppedCommandCount{0};
    ez::sync<EngineConfig> config;
    SPSCQueue<EngineCommand, 256> commandQueue;
    SPSCQueue<ClockSample, 1024> clockSamples;
    SPSCQueue<MeterSample, 1024> meterSamples;
    float transportGain = 1;
    float transportGainTarget = 1;
    float transportGainStep = 0;
    uint64_t transportRampFramesRemaining = 0;
    bool stopWhenTransportRampCompletes = false;
    uint64_t transportPauseFrameIndex = 0;
    bool hasTransportPauseFrameIndex = false;
    std::shared_ptr<const RenderGraph> trackGainRampGraph;
    std::vector<TrackGainRamp> trackGainRamps;
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

uint64_t track_gain_ramp_frame_count(const EngineConfig& config) {
    return config.trackGainRampDurationSeconds > 0 && config.sampleRate > 0 ?
        static_cast<uint64_t>(config.trackGainRampDurationSeconds * config.sampleRate + 0.5) :
        uint64_t{0};
}

void begin_track_gain_ramp(
    TrackGainRamp& ramp,
    float targetGain,
    uint64_t rampFrames
) {
    ramp.targetGain = std::max(targetGain, 0.0f);
    if (rampFrames == 0) {
        ramp.currentGain = ramp.targetGain;
        ramp.gainStep = 0;
        ramp.rampFramesRemaining = 0;
        return;
    }

    ramp.rampFramesRemaining = rampFrames;
    ramp.gainStep = (ramp.targetGain - ramp.currentGain) / static_cast<float>(rampFrames);
}

float next_track_gain(TrackGainRamp& ramp) {
    if (ramp.rampFramesRemaining == 0) {
        return ramp.currentGain;
    }

    ramp.currentGain += ramp.gainStep;
    ramp.rampFramesRemaining--;
    if (ramp.rampFramesRemaining == 0) {
        ramp.currentGain = ramp.targetGain;
        ramp.gainStep = 0;
    }

    return ramp.currentGain;
}

float clamp_audio_sample(float sample) {
    if (sample > 1.0f) {
        return 1.0f;
    }
    if (sample < -1.0f) {
        return -1.0f;
    }
    return sample;
}

uint16_t read_u16_le(const uint8_t* bytes) {
    return static_cast<uint16_t>(bytes[0]) |
        static_cast<uint16_t>(static_cast<uint16_t>(bytes[1]) << 8);
}

uint32_t read_u32_le(const uint8_t* bytes) {
    return static_cast<uint32_t>(bytes[0]) |
        (static_cast<uint32_t>(bytes[1]) << 8) |
        (static_cast<uint32_t>(bytes[2]) << 16) |
        (static_cast<uint32_t>(bytes[3]) << 24);
}

uint64_t read_u64_le(const uint8_t* bytes) {
    return static_cast<uint64_t>(read_u32_le(bytes)) |
        (static_cast<uint64_t>(read_u32_le(bytes + 4)) << 32);
}

int32_t read_i24_le(const uint8_t* bytes) {
    auto value = static_cast<int32_t>(
        static_cast<uint32_t>(bytes[0]) |
        (static_cast<uint32_t>(bytes[1]) << 8) |
        (static_cast<uint32_t>(bytes[2]) << 16)
    );
    if ((value & 0x0080'0000) != 0) {
        value |= static_cast<int32_t>(0xFF00'0000);
    }
    return value;
}

float decode_wav_sample_at(const AudioSource& source, uint64_t frameIndex, uint32_t channelIndex) {
    const auto bytesPerSample = source.wavBitsPerSample / 8;
    if (
        source.wavBytes == nullptr ||
        bytesPerSample == 0 ||
        frameIndex >= source.frameCount ||
        channelIndex >= source.channelCount
    ) {
        return 0.0f;
    }

    const auto byteOffset = source.wavDataOffset +
        frameIndex * source.wavBlockAlign +
        static_cast<uint64_t>(channelIndex) * bytesPerSample;
    if (byteOffset + bytesPerSample > source.wavByteCount) {
        return 0.0f;
    }

    const auto* sampleBytes = source.wavBytes + byteOffset;
    switch (source.wavFormatTag) {
    case 1:
        switch (source.wavBitsPerSample) {
        case 8:
            return clamp_audio_sample((static_cast<float>(sampleBytes[0]) - 128.0f) / 128.0f);
        case 16: {
            const auto sample = static_cast<int16_t>(read_u16_le(sampleBytes));
            return clamp_audio_sample(static_cast<float>(sample) / 32'768.0f);
        }
        case 24:
            return clamp_audio_sample(static_cast<float>(read_i24_le(sampleBytes)) / 8'388'608.0f);
        case 32: {
            const auto sample = static_cast<int32_t>(read_u32_le(sampleBytes));
            return clamp_audio_sample(static_cast<float>(sample) / 2'147'483'648.0f);
        }
        default:
            return 0.0f;
        }
    case 3:
        switch (source.wavBitsPerSample) {
        case 32: {
            const auto bits = read_u32_le(sampleBytes);
            auto sample = float{};
            std::memcpy(&sample, &bits, sizeof(sample));
            return clamp_audio_sample(sample);
        }
        case 64: {
            const auto bits = read_u64_le(sampleBytes);
            auto sample = double{};
            std::memcpy(&sample, &bits, sizeof(sample));
            return clamp_audio_sample(static_cast<float>(sample));
        }
        default:
            return 0.0f;
        }
    default:
        return 0.0f;
    }
}

float sample_at(const AudioSource& source, uint64_t frameIndex, uint32_t channelIndex) {
    if (frameIndex >= source.frameCount || channelIndex >= source.channelCount) {
        return 0.0f;
    }

    if (source.storage == AudioSource::Storage::wavBytes) {
        return decode_wav_sample_at(source, frameIndex, channelIndex);
    }

    const auto sampleIndex = frameIndex * source.channelCount + channelIndex;
    if (sampleIndex >= source.interleavedSamples.size()) {
        return 0.0f;
    }

    return source.interleavedSamples[sampleIndex];
}

float sample_at_linear(const AudioSource& source, double framePosition, uint32_t channelIndex) {
    if (
        !std::isfinite(framePosition) ||
        framePosition < 0 ||
        channelIndex >= source.channelCount ||
        source.frameCount == 0
    ) {
        return 0.0f;
    }

    const auto lowerFrameDouble = std::floor(framePosition);
    if (lowerFrameDouble >= static_cast<double>(source.frameCount)) {
        return 0.0f;
    }

    const auto lowerFrame = static_cast<uint64_t>(lowerFrameDouble);
    const auto upperFrame = lowerFrame + 1;
    const auto lowerSample = sample_at(source, lowerFrame, channelIndex);
    if (upperFrame >= source.frameCount) {
        return lowerSample;
    }

    const auto upperSample = sample_at(source, upperFrame, channelIndex);
    const auto fraction = static_cast<float>(framePosition - lowerFrameDouble);
    return lowerSample + (upperSample - lowerSample) * fraction;
}

uint64_t output_frame_count_for_source(const AudioSource& source, double outputSampleRate) {
    if (source.frameCount == 0 || source.sampleRate <= 0 || outputSampleRate <= 0) {
        return 0;
    }

    const auto outputFrameCount = std::ceil(
        static_cast<double>(source.frameCount) * outputSampleRate / source.sampleRate
    );
    if (!std::isfinite(outputFrameCount) || outputFrameCount <= 0) {
        return 0;
    }

    return static_cast<uint64_t>(outputFrameCount);
}

void reconcile_track_gain_ramps(
    SoundtimeAudioCoreEngine& engine,
    const EngineConfig& config,
    const RenderGraph& graph
) {
    if (engine.trackGainRampGraph == config.graph &&
        engine.trackGainRamps.size() == graph.tracks.size()) {
        return;
    }

    const auto rampFrames = track_gain_ramp_frame_count(config);
    const auto previousRampCount = engine.trackGainRamps.size();
    engine.trackGainRamps.resize(graph.tracks.size());
    for (size_t trackIndex = 0; trackIndex < graph.tracks.size(); trackIndex++) {
        const auto& track = graph.tracks[trackIndex];
        auto& ramp = engine.trackGainRamps[trackIndex];
        const auto targetGain = std::max(track.gain, 0.0f);

        if (trackIndex < previousRampCount && ramp.source == track.source) {
            begin_track_gain_ramp(ramp, targetGain, rampFrames);
        } else {
            ramp.source = track.source;
            ramp.currentGain = targetGain;
            ramp.targetGain = targetGain;
            ramp.gainStep = 0;
            ramp.rampFramesRemaining = 0;
        }
    }

    engine.trackGainRampGraph = config.graph;
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
    engine.trackGainRampGraph.reset();
    engine.trackGainRamps.clear();
    engine.commandQueue.clear();
    engine.clockSamples.clear();
    engine.meterSamples.clear();
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
        if (source->sampleRate <= 0 || source->channelCount == 0) {
            return nullptr;
        }

        const auto outputFrameCount = output_frame_count_for_source(*source, sampleRate);
        graph->frameCount = std::max(graph->frameCount, outputFrameCount);
        graph->channelCount = std::max(graph->channelCount, source->channelCount);

        auto track = RenderTrack{
            .source = source,
            .segments = {},
            .gain = std::max(trackConfig.gain, 0.0f),
        };
        if (outputFrameCount > 0) {
            const auto sourceFrameScale = source->sampleRate / sampleRate;
            track.segments.push_back(RenderSegment{
                .outputStartFrame = 0,
                .sourceStartFrame = 0,
                .frameCount = outputFrameCount,
                .sourceFrameScale = sourceFrameScale,
                .usesExactSourceFrames = std::fabs(sourceFrameScale - 1.0) <= 0.000'000'001,
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
            .sourceFrameScale = 1,
            .usesExactSourceFrames = true,
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

void publish_meter_sample(
    SoundtimeAudioCoreEngine& engine,
    float* const* outputs,
    uint32_t channelCount,
    uint32_t frameCount,
    uint64_t startFrameIndex,
    double hostTimestamp,
    bool isPlaying
) {
    if (outputs == nullptr || channelCount == 0 || frameCount == 0) {
        static_cast<void>(engine.meterSamples.push(MeterSample{
            .startFrameIndex = startFrameIndex,
            .frameCount = frameCount,
            .renderedFrameCount = engine.renderedFrameCount.load(std::memory_order_acquire),
            .hostTimestamp = hostTimestamp,
            .isPlaying = isPlaying,
        }));
        return;
    }

    const auto* leftOutput = outputs[0];
    const auto* rightOutput = channelCount > 1 ? outputs[1] : outputs[0];
    auto leftSquareSum = double{0};
    auto rightSquareSum = double{0};
    auto leftPeak = float{0};
    auto rightPeak = float{0};
    auto leftClipPeak = float{0};
    auto rightClipPeak = float{0};
    auto measuredFrameCount = uint32_t{0};

    for (uint32_t frameIndex = 0; frameIndex < frameCount; frameIndex++) {
        const auto leftSample = leftOutput != nullptr ? leftOutput[frameIndex] : 0.0f;
        const auto rightSample = rightOutput != nullptr ? rightOutput[frameIndex] : leftSample;
        const auto leftMagnitude = std::fabs(leftSample);
        const auto rightMagnitude = std::fabs(rightSample);

        leftSquareSum += static_cast<double>(leftSample) * static_cast<double>(leftSample);
        rightSquareSum += static_cast<double>(rightSample) * static_cast<double>(rightSample);
        leftPeak = std::max(leftPeak, leftMagnitude);
        rightPeak = std::max(rightPeak, rightMagnitude);
        if (leftMagnitude > 1.0f) {
            leftClipPeak = std::max(leftClipPeak, leftMagnitude);
        }
        if (rightMagnitude > 1.0f) {
            rightClipPeak = std::max(rightClipPeak, rightMagnitude);
        }
        measuredFrameCount++;
    }

    const auto denominator = measuredFrameCount > 0 ? static_cast<double>(measuredFrameCount) : 1.0;
    static_cast<void>(engine.meterSamples.push(MeterSample{
        .startFrameIndex = startFrameIndex,
        .frameCount = frameCount,
        .renderedFrameCount = engine.renderedFrameCount.load(std::memory_order_acquire),
        .hostTimestamp = hostTimestamp,
        .isPlaying = isPlaying,
        .leftRMS = static_cast<float>(std::sqrt(leftSquareSum / denominator)),
        .rightRMS = static_cast<float>(std::sqrt(rightSquareSum / denominator)),
        .leftPeak = leftPeak,
        .rightPeak = rightPeak,
        .leftClipPeak = leftClipPeak,
        .rightClipPeak = rightClipPeak,
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
) {
    const auto bytesPerSample = bitsPerSample / 8;
    if (
        bytes == nullptr ||
        byteCount == 0 ||
        channelCount == 0 ||
        sampleRate <= 0 ||
        bytesPerSample == 0 ||
        blockAlign < bytesPerSample * channelCount ||
        dataOffset > byteCount ||
        dataOffset + frameCount * static_cast<uint64_t>(blockAlign) > byteCount
    ) {
        return nullptr;
    }

    const auto supportedPCM =
        formatTag == 1 &&
        (bitsPerSample == 8 || bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32);
    const auto supportedFloat =
        formatTag == 3 &&
        (bitsPerSample == 32 || bitsPerSample == 64);
    if (!supportedPCM && !supportedFloat) {
        return nullptr;
    }

    auto source = std::make_shared<AudioSource>();
    source->storage = AudioSource::Storage::wavBytes;
    source->wavBytes = bytes;
    source->wavByteCount = byteCount;
    source->wavDataOffset = dataOffset;
    source->wavBlockAlign = blockAlign;
    source->wavFormatTag = formatTag;
    source->wavBitsPerSample = bitsPerSample;
    source->frameCount = frameCount;
    source->channelCount = channelCount;
    source->sampleRate = sampleRate;

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

bool soundtime_audio_core_pop_meter_sample(
    SoundtimeAudioCoreEngine* engine,
    SoundtimeAudioCoreMeterSample* sample
) {
    if (engine == nullptr || sample == nullptr) {
        return false;
    }

    auto meterSample = MeterSample{};
    if (!engine->meterSamples.pop(meterSample)) {
        return false;
    }

    sample->startFrameIndex = meterSample.startFrameIndex;
    sample->frameCount = meterSample.frameCount;
    sample->renderedFrameCount = meterSample.renderedFrameCount;
    sample->hostTimestamp = meterSample.hostTimestamp;
    sample->isPlaying = meterSample.isPlaying;
    sample->leftRMS = meterSample.leftRMS;
    sample->rightRMS = meterSample.rightRMS;
    sample->leftPeak = meterSample.leftPeak;
    sample->rightPeak = meterSample.rightPeak;
    sample->leftClipPeak = meterSample.leftClipPeak;
    sample->rightClipPeak = meterSample.rightClipPeak;
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
    auto blockStartFrameIndex = uint64_t{0};
    if (engine != nullptr) {
        engine->renderedFrameCount.fetch_add(frameCount, std::memory_order_acq_rel);
        config = engine->config.read(ez::audio);
        process_commands(*engine, *config);
        blockStartFrameIndex = engine->frameIndex.load(std::memory_order_acquire);
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
        publish_meter_sample(
            *engine,
            outputs,
            channelCount,
            frameCount,
            blockStartFrameIndex,
            hostTimestamp,
            false
        );
        publish_clock_sample(*engine);
        return;
    }

    const auto sourceFrameCount = config->frameCount;
    const auto currentFrameIndex = blockStartFrameIndex;
    const auto renderableFrameCount = sourceFrameCount > currentFrameIndex ?
        std::min<uint64_t>(frameCount, sourceFrameCount - currentFrameIndex) :
        0;
    uint64_t advancedFrameCount = 0;
    bool completedTransportStop = false;
    if (const auto& graph = config->graph; graph && !graph->tracks.empty()) {
        reconcile_track_gain_ramps(*engine, *config, *graph);
        for (uint64_t frameOffset = 0; frameOffset < renderableFrameCount; frameOffset++) {
            const auto transportGain = next_transport_gain(*engine, completedTransportStop);
            const auto outputFrameIndex = currentFrameIndex + frameOffset;
            const auto outputGainBase = config->gain * transportGain;

            advancedFrameCount++;
            for (size_t trackIndex = 0; trackIndex < graph->tracks.size(); trackIndex++) {
                const auto& track = graph->tracks[trackIndex];
                const auto& source = track.source;
                const auto trackGain = next_track_gain(engine->trackGainRamps[trackIndex]);
                if (!source || trackGain <= 0) {
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

                    const auto sourceChannelCount = source->channelCount;
                    const auto outputGain = outputGainBase * trackGain * segment.gain;
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

                        const auto sourceSample = segment.usesExactSourceFrames ?
                            sample_at(
                                *source,
                                segment.sourceStartFrame + segmentFrameOffset,
                                sourceChannel
                            ) :
                            sample_at_linear(
                                *source,
                                static_cast<double>(segment.sourceStartFrame) +
                                    static_cast<double>(segmentFrameOffset) * segment.sourceFrameScale,
                                sourceChannel
                            );
                        output[frameOffset] += sourceSample * outputGain;
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
    auto finalHostTimestamp = hostTimestamp;
    if (hostTimestamp > 0 && config->sampleRate > 0) {
        const auto renderedDuration = static_cast<double>(advancedFrameCount) / config->sampleRate;
        finalHostTimestamp = hostTimestamp + renderedDuration;
        engine->hostTimestamp.store(finalHostTimestamp, std::memory_order_release);
    } else {
        engine->hostTimestamp.store(finalHostTimestamp, std::memory_order_release);
    }
    publish_meter_sample(
        *engine,
        outputs,
        channelCount,
        frameCount,
        currentFrameIndex,
        finalHostTimestamp,
        engine->isPlaying.load(std::memory_order_acquire)
    );
    publish_clock_sample(*engine);
}
