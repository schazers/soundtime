#include "SoundtimeAudioCore.h"

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

constexpr size_t maximumRealtimeTrackCount = 4096;

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
    bool spliceFadeIn = false;
    bool spliceFadeOut = false;
    float gainStart = 1;
    float gainEnd = 1;
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

struct AudioRenderConfig {
    uint64_t frameCount = 0;
    uint32_t channelCount = 0;
    double sampleRate = 0;
    float gain = 1;
    double transportRampDurationSeconds = 0.018;
    double trackGainRampDurationSeconds = 0.003;
    const RenderGraph* graph = nullptr;
};

struct TrackGainRamp {
    const AudioSource* source = nullptr;
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
        trackGainRamps.resize(maximumRealtimeTrackCount);
    }

    std::atomic<uint64_t> frameIndex{0};
    std::atomic<uint64_t> renderedFrameCount{0};
    std::atomic<double> hostTimestamp{0};
    std::atomic<bool> isPlaying{false};
    std::atomic<uint64_t> underrunCount{0};
    std::atomic<uint64_t> droppedCommandCount{0};
    std::atomic<uint64_t> configFrameCount{0};
    std::atomic<uint32_t> configChannelCount{0};
    std::atomic<double> configSampleRate{0};
    std::atomic<float> configGain{1};
    std::atomic<double> configTransportRampDurationSeconds{0.018};
    std::atomic<double> configTrackGainRampDurationSeconds{0.003};
    std::atomic<const RenderGraph*> currentGraph{nullptr};
    std::atomic<const RenderGraph*> renderGraphInUse{nullptr};
    std::mutex graphLifetimeMutex;
    std::shared_ptr<const RenderGraph> currentGraphOwner;
    std::vector<std::shared_ptr<const RenderGraph>> retiredGraphs;
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
    const RenderGraph* trackGainRampGraph = nullptr;
    size_t trackGainRampCount = 0;
    std::vector<TrackGainRamp> trackGainRamps;
};

struct SoundtimeAudioCoreSource {
    std::shared_ptr<const AudioSource> source;
};

struct SoundtimeAudioCoreRecordingRing {
    uint32_t channelCount = 0;
    uint64_t frameCapacity = 0;
    double sampleRate = 0;
    std::vector<float> planarSamples;
    std::atomic<uint64_t> writeFrame{0};
    std::atomic<uint64_t> readFrame{0};
    std::atomic<uint64_t> droppedFrameCount{0};
    std::atomic<double> lastHostTimestamp{0};
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
    const AudioRenderConfig& config,
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

uint64_t track_gain_ramp_frame_count(const AudioRenderConfig& config) {
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

float smoothstep(float progress) {
    const auto clampedProgress = std::clamp(progress, 0.0f, 1.0f);
    return clampedProgress * clampedProgress * (3.0f - 2.0f * clampedProgress);
}

float segment_gain(const RenderSegment& segment, uint64_t segmentFrameOffset) {
    if (segment.frameCount <= 1 || std::fabs(segment.gainStart - segment.gainEnd) <= 0.000'001f) {
        return segment.gainEnd;
    }

    const auto progress = static_cast<float>(
        static_cast<double>(std::min(segmentFrameOffset, segment.frameCount - 1)) /
            static_cast<double>(segment.frameCount - 1)
    );
    return segment.gainStart + (segment.gainEnd - segment.gainStart) * smoothstep(progress);
}

uint64_t splice_fade_frame_count(const RenderSegment& segment, const AudioRenderConfig& config) {
    constexpr auto spliceFadeDurationSeconds = 0.005;
    if (segment.frameCount < 4 || config.sampleRate <= 0) {
        return 0;
    }

    const auto requestedFrames = static_cast<uint64_t>(
        spliceFadeDurationSeconds * config.sampleRate + 0.5
    );
    return std::min<uint64_t>(
        std::max<uint64_t>(requestedFrames, 2),
        std::max<uint64_t>(segment.frameCount / 2, 1)
    );
}

float segment_splice_gain(
    const RenderSegment& segment,
    uint64_t segmentFrameOffset,
    const AudioRenderConfig& config
) {
    auto gain = 1.0f;
    const auto fadeFrameCount = splice_fade_frame_count(segment, config);
    if (fadeFrameCount <= 1) {
        return gain;
    }

    if (segment.spliceFadeIn && segmentFrameOffset < fadeFrameCount) {
        const auto progress = static_cast<float>(
            static_cast<double>(segmentFrameOffset) / static_cast<double>(fadeFrameCount - 1)
        );
        gain *= smoothstep(progress);
    }
    if (segment.spliceFadeOut && segment.frameCount > segmentFrameOffset) {
        const auto framesFromEnd = segment.frameCount - segmentFrameOffset - 1;
        if (framesFromEnd < fadeFrameCount) {
            const auto progress = static_cast<float>(
                static_cast<double>(fadeFrameCount - framesFromEnd - 1) /
                    static_cast<double>(fadeFrameCount - 1)
            );
            gain *= 1.0f - smoothstep(progress);
        }
    }

    return gain;
}

bool adjacent_segments_need_splice_fade(
    const RenderSegment& previous,
    const RenderSegment& next
) {
    if (previous.outputStartFrame + previous.frameCount != next.outputStartFrame) {
        return false;
    }
    if (std::fabs(previous.gainEnd - next.gainStart) > 0.000'001f) {
        return true;
    }
    if (std::fabs(previous.sourceFrameScale - next.sourceFrameScale) > 0.000'000'001) {
        return true;
    }

    const auto previousSourceEnd = previous.sourceStartFrame + static_cast<uint64_t>(
        static_cast<double>(previous.frameCount) * previous.sourceFrameScale + 0.5
    );
    return previousSourceEnd != next.sourceStartFrame;
}

void mark_splice_fades(RenderTrack& track) {
    if (track.segments.size() < 2) {
        return;
    }

    for (size_t segmentIndex = 1; segmentIndex < track.segments.size(); segmentIndex++) {
        auto& previous = track.segments[segmentIndex - 1];
        auto& next = track.segments[segmentIndex];
        if (!adjacent_segments_need_splice_fade(previous, next)) {
            continue;
        }

        previous.spliceFadeOut = true;
        next.spliceFadeIn = true;
    }
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
    const AudioRenderConfig& config,
    const RenderGraph& graph
) {
    const auto trackCount = graph.tracks.size();
    if (trackCount > engine.trackGainRamps.size()) {
        return;
    }

    if (engine.trackGainRampGraph == config.graph &&
        engine.trackGainRampCount == trackCount) {
        return;
    }

    const auto rampFrames = track_gain_ramp_frame_count(config);
    const auto previousRampCount = engine.trackGainRampCount;
    for (size_t trackIndex = 0; trackIndex < trackCount; trackIndex++) {
        const auto& track = graph.tracks[trackIndex];
        auto& ramp = engine.trackGainRamps[trackIndex];
        const auto targetGain = std::max(track.gain, 0.0f);
        const auto* source = track.source.get();

        if (trackIndex < previousRampCount && ramp.source == source) {
            begin_track_gain_ramp(ramp, targetGain, rampFrames);
        } else {
            ramp.source = source;
            ramp.currentGain = targetGain;
            ramp.targetGain = targetGain;
            ramp.gainStep = 0;
            ramp.rampFramesRemaining = 0;
        }
    }

    engine.trackGainRampGraph = config.graph;
    engine.trackGainRampCount = trackCount;
}

void process_commands(SoundtimeAudioCoreEngine& engine, const AudioRenderConfig& config) {
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
    engine.trackGainRampGraph = nullptr;
    engine.trackGainRampCount = 0;
    engine.commandQueue.clear();
    engine.clockSamples.clear();
    engine.meterSamples.clear();
}

void gc_retired_graphs_locked(SoundtimeAudioCoreEngine& engine) {
    // Render graphs are tiny immutable routing/edit descriptions; they do not own
    // decoded sample buffers beyond shared source references. Keep retired graphs
    // for the engine lifetime so the realtime callback never observes memory that
    // was reclaimed between graph publication and render acquisition.
    static_cast<void>(engine);
}

void publish_render_config(
    SoundtimeAudioCoreEngine& engine,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate,
    std::shared_ptr<const RenderGraph> graph
) {
    std::lock_guard lock(engine.graphLifetimeMutex);

    auto previousGraph = std::move(engine.currentGraphOwner);
    engine.currentGraphOwner = std::move(graph);
    if (previousGraph) {
        engine.retiredGraphs.push_back(std::move(previousGraph));
    }

    engine.configFrameCount.store(frameCount, std::memory_order_release);
    engine.configChannelCount.store(channelCount, std::memory_order_release);
    engine.configSampleRate.store(sampleRate, std::memory_order_release);
    engine.currentGraph.store(engine.currentGraphOwner.get(), std::memory_order_release);
    gc_retired_graphs_locked(engine);
}

void clear_render_graph(
    SoundtimeAudioCoreEngine& engine,
    uint64_t frameCount,
    uint32_t channelCount,
    double sampleRate
) {
    std::lock_guard lock(engine.graphLifetimeMutex);

    auto previousGraph = std::move(engine.currentGraphOwner);
    engine.currentGraph.store(nullptr, std::memory_order_release);
    if (previousGraph) {
        engine.retiredGraphs.push_back(std::move(previousGraph));
    }

    engine.configFrameCount.store(frameCount, std::memory_order_release);
    engine.configChannelCount.store(channelCount, std::memory_order_release);
    engine.configSampleRate.store(sampleRate, std::memory_order_release);
    gc_retired_graphs_locked(engine);
}

const RenderGraph* acquire_render_graph(SoundtimeAudioCoreEngine& engine) {
    while (true) {
        const auto* graph = engine.currentGraph.load(std::memory_order_acquire);
        engine.renderGraphInUse.store(graph, std::memory_order_release);
        if (graph == engine.currentGraph.load(std::memory_order_acquire)) {
            return graph;
        }
    }
}

void release_render_graph(SoundtimeAudioCoreEngine& engine) {
    engine.renderGraphInUse.store(nullptr, std::memory_order_release);
}

AudioRenderConfig make_audio_render_config(
    const SoundtimeAudioCoreEngine& engine,
    const RenderGraph* graph
) {
    if (graph != nullptr) {
        return AudioRenderConfig{
            .frameCount = graph->frameCount,
            .channelCount = graph->channelCount,
            .sampleRate = graph->sampleRate,
            .gain = engine.configGain.load(std::memory_order_acquire),
            .transportRampDurationSeconds =
                engine.configTransportRampDurationSeconds.load(std::memory_order_acquire),
            .trackGainRampDurationSeconds =
                engine.configTrackGainRampDurationSeconds.load(std::memory_order_acquire),
            .graph = graph,
        };
    }

    return AudioRenderConfig{
        .frameCount = engine.configFrameCount.load(std::memory_order_acquire),
        .channelCount = engine.configChannelCount.load(std::memory_order_acquire),
        .sampleRate = engine.configSampleRate.load(std::memory_order_acquire),
        .gain = engine.configGain.load(std::memory_order_acquire),
        .transportRampDurationSeconds =
            engine.configTransportRampDurationSeconds.load(std::memory_order_acquire),
        .trackGainRampDurationSeconds =
            engine.configTrackGainRampDurationSeconds.load(std::memory_order_acquire),
        .graph = nullptr,
    };
}

void publish_graph(
    SoundtimeAudioCoreEngine& engine,
    std::shared_ptr<const RenderGraph> graph,
    bool resetRuntime
) {
    if (resetRuntime) {
        reset_engine_runtime(engine);
    }
    publish_render_config(
        engine,
        graph->frameCount,
        graph->channelCount,
        graph->sampleRate,
        std::move(graph)
    );
}

std::shared_ptr<RenderGraph> make_graph_from_track_configs(
    const SoundtimeAudioCoreTrackConfig* tracks,
    uint32_t trackCount
) {
    if (tracks == nullptr || trackCount == 0) {
        return nullptr;
    }
    if (trackCount > maximumRealtimeTrackCount) {
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
                .gainStart = 1,
                .gainEnd = 1,
            });
        }
        graph->tracks.push_back(std::move(track));
    }

    if (graph->channelCount == 0 || graph->frameCount == 0) {
        return nullptr;
    }

    return graph;
}

std::shared_ptr<RenderGraph> make_graph_from_segmented_track_configs(
    const SoundtimeAudioCoreSegmentedTrackConfig* tracks,
    uint32_t trackCount
) {
    if (tracks == nullptr || trackCount == 0) {
        return nullptr;
    }
    if (trackCount > maximumRealtimeTrackCount) {
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

        graph->channelCount = std::max(graph->channelCount, source->channelCount);

        auto track = RenderTrack{
            .source = source,
            .segments = {},
            .gain = std::max(trackConfig.gain, 0.0f),
        };

        if (trackConfig.segmentCount == 0 || trackConfig.segments == nullptr) {
            const auto outputFrameCount = output_frame_count_for_source(*source, sampleRate);
            graph->frameCount = std::max(graph->frameCount, outputFrameCount);
            if (outputFrameCount > 0) {
                const auto sourceFrameScale = source->sampleRate / sampleRate;
                track.segments.push_back(RenderSegment{
                    .outputStartFrame = 0,
                    .sourceStartFrame = 0,
                    .frameCount = outputFrameCount,
                    .sourceFrameScale = sourceFrameScale,
                    .usesExactSourceFrames = std::fabs(sourceFrameScale - 1.0) <= 0.000'000'001,
                    .gainStart = 1,
                    .gainEnd = 1,
                });
            }
        } else {
            track.segments.reserve(trackConfig.segmentCount);
            for (uint32_t segmentIndex = 0; segmentIndex < trackConfig.segmentCount; segmentIndex++) {
                const auto& segmentConfig = trackConfig.segments[segmentIndex];
                if (segmentConfig.frameCount == 0) {
                    continue;
                }

                const auto sourceFrameScale = segmentConfig.sourceFrameScale > 0 ?
                    segmentConfig.sourceFrameScale :
                    source->sampleRate / sampleRate;
                track.segments.push_back(RenderSegment{
                    .outputStartFrame = segmentConfig.outputStartFrame,
                    .sourceStartFrame = segmentConfig.sourceStartFrame,
                    .frameCount = segmentConfig.frameCount,
                    .sourceFrameScale = sourceFrameScale,
                    .usesExactSourceFrames = std::fabs(sourceFrameScale - 1.0) <= 0.000'000'001,
                    .gainStart = std::max(segmentConfig.gainStart, 0.0f),
                    .gainEnd = std::max(segmentConfig.gainEnd, 0.0f),
                });
                graph->frameCount = std::max(
                    graph->frameCount,
                    segmentConfig.outputStartFrame + segmentConfig.frameCount
                );
            }
        }

        mark_splice_fades(track);
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
            .gainStart = 1,
            .gainEnd = 1,
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
    engine->configGain.store(1, std::memory_order_release);
    engine->configTransportRampDurationSeconds.store(0.018, std::memory_order_release);
    engine->configTrackGainRampDurationSeconds.store(0.003, std::memory_order_release);
    clear_render_graph(*engine, 0, 0, 0);
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
    clear_render_graph(*engine, frameCount, channelCount, sampleRate);
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

bool soundtime_audio_core_set_prepared_segmented_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreSegmentedTrackConfig* tracks,
    uint32_t trackCount
) {
    if (engine == nullptr) {
        return false;
    }

    const auto graph = make_graph_from_segmented_track_configs(tracks, trackCount);
    if (!graph) {
        return false;
    }

    publish_graph(*engine, graph, true);
    return true;
}

bool soundtime_audio_core_update_prepared_segmented_tracks(
    SoundtimeAudioCoreEngine* engine,
    const SoundtimeAudioCoreSegmentedTrackConfig* tracks,
    uint32_t trackCount
) {
    if (engine == nullptr) {
        return false;
    }

    const auto graph = make_graph_from_segmented_track_configs(tracks, trackCount);
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

    engine->configGain.store(std::max(gain, 0.0f), std::memory_order_release);
}

void soundtime_audio_core_set_transport_ramp_duration(
    SoundtimeAudioCoreEngine* engine,
    double durationSeconds
) {
    if (engine == nullptr) {
        return;
    }

    engine->configTransportRampDurationSeconds.store(
        std::max(durationSeconds, 0.0),
        std::memory_order_release
    );
}

SoundtimeAudioCoreSnapshot soundtime_audio_core_snapshot(const SoundtimeAudioCoreEngine* engine) {
    if (engine == nullptr) {
        return SoundtimeAudioCoreSnapshot{};
    }

    return SoundtimeAudioCoreSnapshot{
        .frameIndex = engine->frameIndex.load(std::memory_order_acquire),
        .frameCount = engine->configFrameCount.load(std::memory_order_acquire),
        .sampleRate = engine->configSampleRate.load(std::memory_order_acquire),
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

    auto config = AudioRenderConfig{};
    auto blockStartFrameIndex = uint64_t{0};
    const auto* graph = static_cast<const RenderGraph*>(nullptr);
    if (engine != nullptr) {
        engine->renderedFrameCount.fetch_add(frameCount, std::memory_order_acq_rel);
        graph = acquire_render_graph(*engine);
        config = make_audio_render_config(*engine, graph);
        process_commands(*engine, config);
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
        release_render_graph(*engine);
        return;
    }

    const auto sourceFrameCount = config.frameCount;
    const auto currentFrameIndex = blockStartFrameIndex;
    const auto renderableFrameCount = sourceFrameCount > currentFrameIndex ?
        std::min<uint64_t>(frameCount, sourceFrameCount - currentFrameIndex) :
        0;
    uint64_t advancedFrameCount = 0;
    bool completedTransportStop = false;
    if (graph != nullptr && !graph->tracks.empty()) {
        reconcile_track_gain_ramps(*engine, config, *graph);
        for (uint64_t frameOffset = 0; frameOffset < renderableFrameCount; frameOffset++) {
            const auto transportGain = next_transport_gain(*engine, completedTransportStop);
            const auto outputFrameIndex = currentFrameIndex + frameOffset;
            const auto outputGainBase = config.gain * transportGain;

            advancedFrameCount++;
            for (size_t trackIndex = 0; trackIndex < graph->tracks.size(); trackIndex++) {
                const auto& track = graph->tracks[trackIndex];
                const auto* source = track.source.get();
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
                    const auto outputGain = outputGainBase *
                        trackGain *
                        segment_gain(segment, segmentFrameOffset) *
                        segment_splice_gain(segment, segmentFrameOffset, config);
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
    if (hostTimestamp > 0 && config.sampleRate > 0) {
        const auto renderedDuration = static_cast<double>(advancedFrameCount) / config.sampleRate;
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
    release_render_graph(*engine);
}

SoundtimeAudioCoreRecordingRing* soundtime_audio_core_recording_ring_create(
    uint32_t channelCount,
    uint64_t frameCapacity,
    double sampleRate
) {
    if (channelCount == 0 || frameCapacity == 0 || !std::isfinite(sampleRate) || sampleRate <= 0) {
        return nullptr;
    }

    auto ring = std::make_unique<SoundtimeAudioCoreRecordingRing>();
    ring->channelCount = std::min<uint32_t>(channelCount, 8);
    ring->frameCapacity = std::max<uint64_t>(frameCapacity, 1);
    ring->sampleRate = sampleRate;
    ring->planarSamples.resize(static_cast<size_t>(ring->channelCount * ring->frameCapacity), 0.0f);
    return ring.release();
}

void soundtime_audio_core_recording_ring_destroy(SoundtimeAudioCoreRecordingRing* ring) {
    delete ring;
}

void soundtime_audio_core_recording_ring_reset(SoundtimeAudioCoreRecordingRing* ring) {
    if (ring == nullptr) {
        return;
    }

    const auto writeFrame = ring->writeFrame.load(std::memory_order_acquire);
    ring->readFrame.store(writeFrame, std::memory_order_release);
    ring->droppedFrameCount.store(0, std::memory_order_release);
    ring->lastHostTimestamp.store(0, std::memory_order_release);
}

uint32_t soundtime_audio_core_recording_ring_push_planar(
    SoundtimeAudioCoreRecordingRing* ring,
    const float* const* channels,
    uint32_t channelCount,
    uint32_t frameCount,
    double hostTimestamp
) {
    if (
        ring == nullptr ||
        channels == nullptr ||
        channelCount == 0 ||
        frameCount == 0 ||
        ring->frameCapacity == 0 ||
        ring->channelCount == 0
    ) {
        return 0;
    }

    const auto writeFrame = ring->writeFrame.load(std::memory_order_relaxed);
    const auto readFrame = ring->readFrame.load(std::memory_order_acquire);
    const auto usedFrameCount = std::min<uint64_t>(writeFrame - readFrame, ring->frameCapacity);
    const auto freeFrameCount = ring->frameCapacity - usedFrameCount;
    const auto framesToWrite = static_cast<uint32_t>(
        std::min<uint64_t>(frameCount, freeFrameCount)
    );
    if (framesToWrite < frameCount) {
        ring->droppedFrameCount.fetch_add(frameCount - framesToWrite, std::memory_order_acq_rel);
    }
    if (framesToWrite == 0) {
        return 0;
    }

    const auto inputChannelCount = std::min<uint32_t>(channelCount, ring->channelCount);
    for (uint32_t channelIndex = 0; channelIndex < ring->channelCount; channelIndex++) {
        const auto sourceChannelIndex = std::min<uint32_t>(channelIndex, inputChannelCount - 1);
        const auto* source = channels[sourceChannelIndex];
        auto* destination = ring->planarSamples.data() +
            static_cast<size_t>(channelIndex) * static_cast<size_t>(ring->frameCapacity);
        for (uint32_t frameOffset = 0; frameOffset < framesToWrite; frameOffset++) {
            const auto ringFrame = (writeFrame + frameOffset) % ring->frameCapacity;
            destination[ringFrame] = source != nullptr ? source[frameOffset] : 0.0f;
        }
    }

    ring->lastHostTimestamp.store(hostTimestamp, std::memory_order_release);
    ring->writeFrame.store(writeFrame + framesToWrite, std::memory_order_release);
    return framesToWrite;
}

uint32_t soundtime_audio_core_recording_ring_pop_planar(
    SoundtimeAudioCoreRecordingRing* ring,
    float* const* channels,
    uint32_t channelCount,
    uint32_t maxFrameCount,
    double* hostTimestamp
) {
    if (
        ring == nullptr ||
        channels == nullptr ||
        channelCount == 0 ||
        maxFrameCount == 0 ||
        ring->frameCapacity == 0 ||
        ring->channelCount == 0
    ) {
        return 0;
    }

    const auto readFrame = ring->readFrame.load(std::memory_order_relaxed);
    const auto writeFrame = ring->writeFrame.load(std::memory_order_acquire);
    const auto availableFrameCount = std::min<uint64_t>(writeFrame - readFrame, ring->frameCapacity);
    const auto framesToRead = static_cast<uint32_t>(
        std::min<uint64_t>(maxFrameCount, availableFrameCount)
    );
    if (framesToRead == 0) {
        return 0;
    }

    const auto outputChannelCount = std::min<uint32_t>(channelCount, ring->channelCount);
    for (uint32_t channelIndex = 0; channelIndex < outputChannelCount; channelIndex++) {
        auto* destination = channels[channelIndex];
        if (destination == nullptr) {
            continue;
        }

        const auto* source = ring->planarSamples.data() +
            static_cast<size_t>(channelIndex) * static_cast<size_t>(ring->frameCapacity);
        for (uint32_t frameOffset = 0; frameOffset < framesToRead; frameOffset++) {
            const auto ringFrame = (readFrame + frameOffset) % ring->frameCapacity;
            destination[frameOffset] = source[ringFrame];
        }
    }

    for (uint32_t channelIndex = outputChannelCount; channelIndex < channelCount; channelIndex++) {
        auto* destination = channels[channelIndex];
        if (destination != nullptr) {
            std::fill(destination, destination + framesToRead, 0.0f);
        }
    }

    if (hostTimestamp != nullptr) {
        *hostTimestamp = ring->lastHostTimestamp.load(std::memory_order_acquire);
    }
    ring->readFrame.store(readFrame + framesToRead, std::memory_order_release);
    return framesToRead;
}

uint64_t soundtime_audio_core_recording_ring_available_frame_count(
    const SoundtimeAudioCoreRecordingRing* ring
) {
    if (ring == nullptr || ring->frameCapacity == 0) {
        return 0;
    }

    const auto writeFrame = ring->writeFrame.load(std::memory_order_acquire);
    const auto readFrame = ring->readFrame.load(std::memory_order_acquire);
    return std::min<uint64_t>(writeFrame - readFrame, ring->frameCapacity);
}

uint64_t soundtime_audio_core_recording_ring_dropped_frame_count(
    const SoundtimeAudioCoreRecordingRing* ring
) {
    if (ring == nullptr) {
        return 0;
    }

    return ring->droppedFrameCount.load(std::memory_order_acquire);
}

uint32_t soundtime_audio_core_recording_ring_channel_count(
    const SoundtimeAudioCoreRecordingRing* ring
) {
    return ring != nullptr ? ring->channelCount : 0;
}

double soundtime_audio_core_recording_ring_sample_rate(
    const SoundtimeAudioCoreRecordingRing* ring
) {
    return ring != nullptr ? ring->sampleRate : 0;
}
