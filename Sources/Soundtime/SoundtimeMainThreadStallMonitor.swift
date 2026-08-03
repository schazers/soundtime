import Foundation
import QuartzCore

final class SoundtimeMainThreadStallMonitor: @unchecked Sendable {
    static let shared = SoundtimeMainThreadStallMonitor()

    private let lock = NSLock()
    private let interval: TimeInterval = 0.25
    private let warningThreshold: TimeInterval = 0.050
    private var timer: CFRunLoopTimer?
    private var isStarted = false
    private var lastHeartbeatTime: TimeInterval = 0
    private var lastReportedStallTime: TimeInterval = 0

    private init() {}

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lastHeartbeatTime = CACurrentMediaTime()
        lock.unlock()

        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + interval,
            interval,
            0,
            0
        ) { [weak self] _ in
            self?.receiveMainRunLoopHeartbeat()
        }
        CFRunLoopTimerSetTolerance(timer, 0.030)

        lock.lock()
        guard isStarted else {
            lock.unlock()
            CFRunLoopTimerInvalidate(timer)
            return
        }
        self.timer = timer
        lock.unlock()
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
    }

    func stop() {
        lock.lock()
        isStarted = false
        let timer = timer
        self.timer = nil
        lock.unlock()
        if let timer {
            CFRunLoopTimerInvalidate(timer)
        }
    }

    func resetForSmokeTesting() {
        lock.lock()
        let now = CACurrentMediaTime()
        lastHeartbeatTime = now
        lastReportedStallTime = now
        lock.unlock()
    }

    private func receiveMainRunLoopHeartbeat() {
        let now = CACurrentMediaTime()
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        let elapsed = now - lastHeartbeatTime
        lastHeartbeatTime = now
        let latency = max(elapsed - interval, 0)
        let shouldReport = latency >= warningThreshold &&
            now - lastReportedStallTime >= 1.0
        if shouldReport {
            lastReportedStallTime = now
        }
        lock.unlock()

        if shouldReport {
            SoundtimeDiagnostics.shared.recordMainThreadStall(milliseconds: latency * 1_000)
        }
    }
}
