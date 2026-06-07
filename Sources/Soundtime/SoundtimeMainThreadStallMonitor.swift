import Foundation
import QuartzCore

final class SoundtimeMainThreadStallMonitor: @unchecked Sendable {
    static let shared = SoundtimeMainThreadStallMonitor()

    private let queue = DispatchQueue(label: "Soundtime.main-thread-stall-monitor", qos: .utility)
    private let lock = NSLock()
    private let interval: TimeInterval = 0.25
    private let warningThreshold: TimeInterval = 0.050
    private var timer: DispatchSourceTimer?
    private var isStarted = false
    private var lastReportedStallTime: TimeInterval = 0

    private init() {}

    func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            self?.pingMainThread()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        lock.lock()
        isStarted = false
        let timer = timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func pingMainThread() {
        let scheduledTime = CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let latency = CACurrentMediaTime() - scheduledTime
            guard latency >= warningThreshold else {
                return
            }

            lock.lock()
            let now = CACurrentMediaTime()
            let shouldReport = now - lastReportedStallTime >= 1.0
            if shouldReport {
                lastReportedStallTime = now
            }
            lock.unlock()

            if shouldReport {
                SoundtimeDiagnostics.shared.recordMainThreadStall(milliseconds: latency * 1_000)
            }
        }
    }
}
