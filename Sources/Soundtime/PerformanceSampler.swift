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
    var targetFramesPerSecond: Double
    var mainThreadResponsivenessFramesPerSecond: Double
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
    private struct MainThreadStallPenalty {
        let timestamp: CFTimeInterval
        let missedDisplayFrames: Double
    }

    static let shared = PerformanceSampler()

    private let lock = NSLock()
    private let rateWindow: CFTimeInterval = 1.0
    private let activeStaleThreshold: CFTimeInterval = 0.35
    private let retainedTimestampWindow: CFTimeInterval = 2.5

    private var timelinePresentedTimestamps: [CFTimeInterval] = []
    private var timelineCompletedTimestamps: [CFTimeInterval] = []
    private var meterPresentedTimestamps: [CFTimeInterval] = []
    private var timelineInputTimestamps: [CFTimeInterval] = []
    private var mainThreadStallPenalties: [MainThreadStallPenalty] = []
    private var renderDemand: PerformanceRenderDemand = .idle
    private var renderDemandStartedAt = CACurrentMediaTime()
    private var lastMainThreadHeartbeatTimestamp: CFTimeInterval?
    private var targetFramesPerSecond: Double = 144
    private var latestCPUPercent: Double = 0
    private var latestTimelineInputEventKind = "-"
    private var previousCPUWallTime = CACurrentMediaTime()
    private var previousCPUTime = PerformanceSampler.currentCPUTime()

    private init() {}

    func recordTimelineFramePresented(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        append(timestamp, to: &timelinePresentedTimestamps, now: timestamp)
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
        if renderDemand == .idle, demand != .idle {
            // A previous active interval must not contaminate the next one.
            // Otherwise a fresh interaction can temporarily report a very low
            // rate because its first frames are averaged with stale timestamps.
            timelinePresentedTimestamps.removeAll(keepingCapacity: true)
            timelineCompletedTimestamps.removeAll(keepingCapacity: true)
            renderDemandStartedAt = CACurrentMediaTime()
        } else if renderDemand != demand {
            renderDemandStartedAt = CACurrentMediaTime()
        }
        renderDemand = demand
        lock.unlock()
    }

    func updateTargetFramesPerSecond(_ framesPerSecond: Int) {
        lock.lock()
        targetFramesPerSecond = Double(max(framesPerSecond, 1))
        lock.unlock()
    }

    func recordMainThreadHeartbeat(
        at timestamp: CFTimeInterval = CACurrentMediaTime(),
        isApplicationActive: Bool,
        expectedInterval: CFTimeInterval
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }

        trimMainThreadStallPenalties(now: timestamp)
        guard isApplicationActive else {
            lastMainThreadHeartbeatTimestamp = nil
            mainThreadStallPenalties.removeAll(keepingCapacity: true)
            return
        }

        defer {
            lastMainThreadHeartbeatTimestamp = timestamp
        }
        guard let previousTimestamp = lastMainThreadHeartbeatTimestamp else {
            return
        }

        let interval = max(timestamp - previousTimestamp, 0)
        let missedFrames = Self.missedDisplayFrames(
            heartbeatInterval: interval,
            expectedHeartbeatInterval: expectedInterval,
            targetFramesPerSecond: targetFramesPerSecond
        )
        guard missedFrames > 0 else {
            return
        }

        mainThreadStallPenalties.append(MainThreadStallPenalty(
            timestamp: timestamp,
            missedDisplayFrames: min(missedFrames, targetFramesPerSecond)
        ))
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
        let targetFPS = targetFramesPerSecond
        let inputKind = latestTimelineInputEventKind
        let demandAge = max(timestamp - renderDemandStartedAt, 0)
        trimMainThreadStallPenalties(now: timestamp)
        let responsivenessFPS = max(
            targetFPS - mainThreadStallPenalties.reduce(0) { $0 + $1.missedDisplayFrames },
            0
        )
        let renderHealthFPS = Self.effectiveFrameHealthFramesPerSecond(
            measuredFramesPerSecond: presentedFPS,
            targetFramesPerSecond: targetFPS,
            renderDemand: demand,
            activeDemandAge: demandAge
        )
        let graphFPS = Self.effectiveGraphFramesPerSecond(
            renderHealthFramesPerSecond: renderHealthFPS,
            mainThreadResponsivenessFramesPerSecond: responsivenessFPS,
            renderDemand: demand
        )
        lock.unlock()

        return PerformanceMetricsSnapshot(
            timestamp: timestamp,
            timelineFramesPerSecond: presentedFPS,
            timelineCompletedFramesPerSecond: completedFPS,
            timelineGraphFramesPerSecond: graphFPS,
            targetFramesPerSecond: targetFPS,
            mainThreadResponsivenessFramesPerSecond: responsivenessFPS,
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

    static func effectiveFrameHealthFramesPerSecond(
        measuredFramesPerSecond: Double,
        targetFramesPerSecond: Double,
        renderDemand: PerformanceRenderDemand,
        activeDemandAge: CFTimeInterval
    ) -> Double {
        let target = max(targetFramesPerSecond, 1)
        guard renderDemand != .idle else {
            return target
        }

        if measuredFramesPerSecond > 0 {
            return min(measuredFramesPerSecond, target)
        }

        // It takes two presentation timestamps to establish a cadence. Do not
        // report a false zero during that short measurement warm-up.
        return activeDemandAge <= 0.10 ? target : 0
    }

    static func effectiveGraphFramesPerSecond(
        renderHealthFramesPerSecond: Double,
        mainThreadResponsivenessFramesPerSecond: Double,
        renderDemand: PerformanceRenderDemand
    ) -> Double {
        guard renderDemand == .idle else {
            // Active rendering is sampled from timeline submissions driven by
            // CAMetalDisplayLink. A low-frequency diagnostics heartbeat must
            // never override that authoritative cadence.
            return max(renderHealthFramesPerSecond, 0)
        }

        return max(
            min(
                renderHealthFramesPerSecond,
                mainThreadResponsivenessFramesPerSecond
            ),
            0
        )
    }

    static func missedDisplayFrames(
        heartbeatInterval: CFTimeInterval,
        expectedHeartbeatInterval: CFTimeInterval,
        targetFramesPerSecond: Double
    ) -> Double {
        guard
            heartbeatInterval.isFinite,
            expectedHeartbeatInterval.isFinite,
            targetFramesPerSecond.isFinite,
            heartbeatInterval >= 0,
            expectedHeartbeatInterval > 0,
            targetFramesPerSecond > 0
        else {
            return 0
        }

        // Foundation timers are deliberately coalesced and the performance
        // timer has its own tolerance. Ignore normal scheduling variation and
        // count only the delay beyond a healthy heartbeat interval.
        let schedulingTolerance = max(expectedHeartbeatInterval * 0.5, 0.025)
        let excessDelay = heartbeatInterval -
            expectedHeartbeatInterval -
            schedulingTolerance
        return max(excessDelay * targetFramesPerSecond, 0)
    }

    private func trimMainThreadStallPenalties(now: CFTimeInterval) {
        let oldestTimestamp = now - rateWindow
        while let first = mainThreadStallPenalties.first, first.timestamp < oldestTimestamp {
            mainThreadStallPenalties.removeFirst()
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
