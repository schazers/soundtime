import Foundation
import CoreFoundation
import QuartzCore

final class SoundtimeMainThreadStallMonitor: @unchecked Sendable {
    static let shared = SoundtimeMainThreadStallMonitor()

    private let lock = NSLock()
    private let watchdogQueue = DispatchQueue(
        label: "com.soundtime.main-thread-stall-watchdog",
        qos: .userInitiated
    )
    private let interval: TimeInterval = 0.016
    private let warningThreshold: TimeInterval = 0.050
    private var timer: DispatchSourceTimer?
    private var runLoopObserver: CFRunLoopObserver?
    private var isStarted = false
    private var generation: UInt64 = 0
    private var heartbeatPending = false
    private var isMainRunLoopActive = false
    private var activeRunLoopCycleBeganAt: TimeInterval = 0
    private var reportedCurrentRunLoopCycle = false
    private var lastReportedStallTime: TimeInterval = 0

    private init() {}

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        generation &+= 1
        heartbeatPending = false
        isMainRunLoopActive = false
        activeRunLoopCycleBeganAt = CACurrentMediaTime()
        reportedCurrentRunLoopCycle = false
        lock.unlock()

        installRunLoopObserver()

        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.checkMainRunLoopProgress()
        }

        lock.lock()
        guard isStarted else {
            lock.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        isStarted = false
        generation &+= 1
        heartbeatPending = false
        isMainRunLoopActive = false
        reportedCurrentRunLoopCycle = false
        let timer = timer
        self.timer = nil
        let observer = runLoopObserver
        runLoopObserver = nil
        lock.unlock()
        timer?.cancel()
        removeRunLoopObserver(observer)
    }

    func resetForSmokeTesting() {
        lock.lock()
        let now = CACurrentMediaTime()
        generation &+= 1
        heartbeatPending = false
        isMainRunLoopActive = false
        activeRunLoopCycleBeganAt = now
        reportedCurrentRunLoopCycle = false
        lastReportedStallTime = now
        lock.unlock()
    }

    func enqueueHeartbeatForSmokeTesting() {
        lock.lock()
        lastReportedStallTime = -Double.infinity
        lock.unlock()
        requestMainQueueHeartbeat()
    }

    func publishStaleSampleForSmokeTesting(milliseconds: Double) {
        lock.lock()
        let staleGeneration = generation
        lock.unlock()

        resetForSmokeTesting()
        recordStallIfCurrent(
            milliseconds: milliseconds,
            observedGeneration: staleGeneration
        )
    }

    private func installRunLoopObserver() {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            0
        ) { [weak self] _, activity in
            self?.observeMainRunLoop(activity)
        }

        lock.lock()
        guard isStarted, runLoopObserver == nil else {
            lock.unlock()
            return
        }
        runLoopObserver = observer
        lock.unlock()

        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopAddObserver(mainRunLoop, observer, .commonModes)
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func removeRunLoopObserver(_ observer: CFRunLoopObserver?) {
        guard let observer else { return }
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopRemoveObserver(mainRunLoop, observer, .commonModes)
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func observeMainRunLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }

        if activity.contains(.beforeWaiting) || activity.contains(.exit) {
            isMainRunLoopActive = false
            reportedCurrentRunLoopCycle = false
        } else if activity.contains(.entry) ||
            activity.contains(.afterWaiting) ||
            activity.contains(.beforeTimers) ||
            activity.contains(.beforeSources)
        {
            isMainRunLoopActive = true
            activeRunLoopCycleBeganAt = now
            reportedCurrentRunLoopCycle = false
        }
        lock.unlock()
    }

    private func checkMainRunLoopProgress() {
        let now = CACurrentMediaTime()
        lock.lock()
        guard isStarted, isMainRunLoopActive, !reportedCurrentRunLoopCycle else {
            lock.unlock()
            return
        }

        let observedGeneration = generation
        let latency = max(now - activeRunLoopCycleBeganAt, 0)
        let shouldReport = latency >= warningThreshold &&
            now - lastReportedStallTime >= 1.0
        if shouldReport {
            reportedCurrentRunLoopCycle = true
            lastReportedStallTime = now
        }
        lock.unlock()

        if shouldReport {
            recordStallIfCurrent(
                milliseconds: latency * 1_000,
                observedGeneration: observedGeneration
            )
        }
    }

    private func requestMainQueueHeartbeat() {
        lock.lock()
        guard isStarted, !heartbeatPending else {
            lock.unlock()
            return
        }
        heartbeatPending = true
        let requestedGeneration = generation
        let enqueuedAt = CACurrentMediaTime()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.receiveMainQueueHeartbeat(
                generation: requestedGeneration,
                enqueuedAt: enqueuedAt
            )
        }
    }

    private func receiveMainQueueHeartbeat(
        generation receivedGeneration: UInt64,
        enqueuedAt: TimeInterval
    ) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard isStarted, receivedGeneration == generation else {
            lock.unlock()
            return
        }
        heartbeatPending = false
        let latency = max(now - enqueuedAt, 0)
        let shouldReport = latency >= warningThreshold &&
            now - lastReportedStallTime >= 1.0
        if shouldReport {
            lastReportedStallTime = now
        }
        lock.unlock()

        if shouldReport {
            recordStallIfCurrent(
                milliseconds: latency * 1_000,
                observedGeneration: receivedGeneration
            )
        }
    }

    private func recordStallIfCurrent(
        milliseconds: Double,
        observedGeneration: UInt64
    ) {
        // Keep reset and publication in one ordering domain. Without this
        // second generation check, a watchdog sample can pass its first check,
        // lose the queue, and publish into the next smoke scenario after that
        // scenario has reset its counters.
        lock.lock()
        guard isStarted, generation == observedGeneration else {
            lock.unlock()
            return
        }
        SoundtimeDiagnostics.shared.recordMainThreadStall(milliseconds: milliseconds)
        lock.unlock()
    }
}
