import Darwin
import Foundation
import QuartzCore

enum PerformanceRenderDemand: String, Sendable {
    case idle
    case playback
    case interaction
    case animation
    case processing
}

struct PerformanceMetricsSnapshot: Equatable, Sendable {
    var timestamp: CFTimeInterval
    var timelineFramesPerSecond: Double
    var timelineCompletedFramesPerSecond: Double
    var timelineGraphFramesPerSecond: Double
    var timelineGraphIsIdle: Bool
    var lastActiveTimelineFramesPerSecond: Double
    var meterFramesPerSecond: Double
    var cpuPercent: Double
    var renderDemand: PerformanceRenderDemand
    var lastTimelineFrameAge: CFTimeInterval?
    var lastCompletedTimelineFrameAge: CFTimeInterval?
    var lastMeterFrameAge: CFTimeInterval?
    var timelineInputEventsPerSecond: Double
    var lastTimelineInputEventAge: CFTimeInterval?
    var latestTimelineInputEventKind: String
}

final class PerformanceSampler: @unchecked Sendable {
    static let shared = PerformanceSampler()

    private let lock = NSLock()
    private let rateWindow: CFTimeInterval = 1.0
    private let activeStaleThreshold: CFTimeInterval = 0.35
    private let retainedTimestampWindow: CFTimeInterval = 2.5

    private var timelinePresentedTimestamps: [CFTimeInterval] = []
    private var timelineCompletedTimestamps: [CFTimeInterval] = []
    private var meterPresentedTimestamps: [CFTimeInterval] = []
    private var timelineInputTimestamps: [CFTimeInterval] = []
    private var renderDemand: PerformanceRenderDemand = .idle
    private var lastActiveTimelineFramesPerSecond: Double = 0
    private var targetFramesPerSecond: Double = 144
    private var latestCPUPercent: Double = 0
    private var latestTimelineInputEventKind = "-"
    private var previousCPUWallTime = CACurrentMediaTime()
    private var previousCPUTime = PerformanceSampler.currentCPUTime()

    private init() {}

    func recordTimelineFramePresented(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        append(timestamp, to: &timelinePresentedTimestamps, now: timestamp)
        if renderDemand != .idle {
            updateLastActiveTimelineFramesPerSecond(now: timestamp)
        }
        lock.unlock()
    }

    func recordTimelineFrameCompleted(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        append(timestamp, to: &timelineCompletedTimestamps, now: timestamp)
        lock.unlock()
    }

    func recordMeterFramePresented(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        append(timestamp, to: &meterPresentedTimestamps, now: timestamp)
        lock.unlock()
    }

    func recordTimelineInputEvent(kind: String, at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        append(timestamp, to: &timelineInputTimestamps, now: timestamp)
        latestTimelineInputEventKind = kind
        lock.unlock()
    }

    func updateRenderDemand(_ demand: PerformanceRenderDemand) {
        lock.lock()
        renderDemand = demand
        lock.unlock()
    }

    func updateTargetFramesPerSecond(_ framesPerSecond: Int) {
        lock.lock()
        targetFramesPerSecond = Double(max(framesPerSecond, 1))
        lock.unlock()
    }

    @discardableResult
    func sampleCPU(at timestamp: CFTimeInterval = CACurrentMediaTime()) -> Double {
        let cpuTime = Self.currentCPUTime()

        lock.lock()
        defer {
            previousCPUWallTime = timestamp
            previousCPUTime = cpuTime
            lock.unlock()
        }

        let wallDelta = max(timestamp - previousCPUWallTime, 0.001)
        let cpuDelta = max(cpuTime - previousCPUTime, 0)
        let rawProcessCPUPercent = cpuDelta / wallDelta * 100
        let coreCount = max(Double(ProcessInfo.processInfo.activeProcessorCount), 1)
        let normalizedCPUPercent = min(max(rawProcessCPUPercent / coreCount, 0), 100)
        latestCPUPercent = normalizedCPUPercent
        return latestCPUPercent
    }

    func sampleAndSnapshot(at timestamp: CFTimeInterval = CACurrentMediaTime()) -> PerformanceMetricsSnapshot {
        _ = sampleCPU(at: timestamp)
        return snapshot(at: timestamp)
    }

    func snapshot(at timestamp: CFTimeInterval = CACurrentMediaTime()) -> PerformanceMetricsSnapshot {
        lock.lock()
        trim(&timelinePresentedTimestamps, now: timestamp)
        trim(&timelineCompletedTimestamps, now: timestamp)
        trim(&meterPresentedTimestamps, now: timestamp)
        trim(&timelineInputTimestamps, now: timestamp)

        let presentedFPS = framesPerSecond(from: timelinePresentedTimestamps, now: timestamp)
        let completedFPS = framesPerSecond(from: timelineCompletedTimestamps, now: timestamp)
        let meterFPS = framesPerSecond(from: meterPresentedTimestamps, now: timestamp)
        let inputRate = framesPerSecond(from: timelineInputTimestamps, now: timestamp)
        let timelineAge = timelinePresentedTimestamps.last.map { timestamp - $0 }
        let completedAge = timelineCompletedTimestamps.last.map { timestamp - $0 }
        let meterAge = meterPresentedTimestamps.last.map { timestamp - $0 }
        let inputAge = timelineInputTimestamps.last.map { timestamp - $0 }
        let demand = renderDemand
        let cpu = latestCPUPercent
        let lastActive = lastActiveTimelineFramesPerSecond
        let targetFPS = targetFramesPerSecond
        let inputKind = latestTimelineInputEventKind
        let isIdleGraphSample = demand == .idle
        let graphFPS = isIdleGraphSample ? (lastActive > 1 ? lastActive : targetFPS) : presentedFPS
        lock.unlock()

        return PerformanceMetricsSnapshot(
            timestamp: timestamp,
            timelineFramesPerSecond: presentedFPS,
            timelineCompletedFramesPerSecond: completedFPS,
            timelineGraphFramesPerSecond: graphFPS,
            timelineGraphIsIdle: isIdleGraphSample,
            lastActiveTimelineFramesPerSecond: lastActive,
            meterFramesPerSecond: meterFPS,
            cpuPercent: cpu,
            renderDemand: demand,
            lastTimelineFrameAge: timelineAge,
            lastCompletedTimelineFrameAge: completedAge,
            lastMeterFrameAge: meterAge,
            timelineInputEventsPerSecond: inputRate,
            lastTimelineInputEventAge: inputAge,
            latestTimelineInputEventKind: inputKind
        )
    }

    private func updateLastActiveTimelineFramesPerSecond(now: CFTimeInterval) {
        let measuredFPS = framesPerSecond(from: timelinePresentedTimestamps, now: now)
        if measuredFPS > 1 {
            lastActiveTimelineFramesPerSecond = measuredFPS
        }
    }

    private func append(
        _ timestamp: CFTimeInterval,
        to timestamps: inout [CFTimeInterval],
        now: CFTimeInterval
    ) {
        timestamps.append(timestamp)
        trim(&timestamps, now: now)
    }

    private func trim(_ timestamps: inout [CFTimeInterval], now: CFTimeInterval) {
        let oldestRetainedTimestamp = now - retainedTimestampWindow
        while let first = timestamps.first, first < oldestRetainedTimestamp {
            timestamps.removeFirst()
        }
    }

    private func framesPerSecond(from timestamps: [CFTimeInterval], now: CFTimeInterval) -> Double {
        guard
            let latestTimestamp = timestamps.last,
            now - latestTimestamp <= activeStaleThreshold
        else {
            return 0
        }

        let oldestTimestamp = now - rateWindow
        let recentTimestamps = timestamps.filter { $0 >= oldestTimestamp }
        guard recentTimestamps.count >= 2, let first = recentTimestamps.first, let last = recentTimestamps.last else {
            return 0
        }

        let span = max(last - first, 0.001)
        return min(max(Double(recentTimestamps.count - 1) / span, 0), 999)
    }

    private static func currentCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0
        }

        let user = TimeInterval(usage.ru_utime.tv_sec) +
            TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec) +
            TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
