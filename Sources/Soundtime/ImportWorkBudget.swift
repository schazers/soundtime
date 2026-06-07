import Foundation
import Dispatch

struct ImportWorkBudgetSnapshot: Sendable {
    let isPlaybackActive: Bool
    let exclusiveWorkInFlight: Int
    let completedWorkCount: Int
    let deferredWorkCount: Int
    let totalDeferredSeconds: TimeInterval
    let lastDeferredWorkClass: String
}

final class ImportWorkBudget: @unchecked Sendable {
    enum WorkClass: String, Sendable {
        case initialPreview
        case previewRefinement
        case backgroundDecode
        case rendererMaintenance
        case zeroCrossingAnalysis

        var playbackBackoff: TimeInterval {
            switch self {
            case .initialPreview:
                0
            case .previewRefinement:
                0.003
            case .backgroundDecode:
                0.010
            case .rendererMaintenance:
                0.002
            case .zeroCrossingAnalysis:
                0.004
            }
        }
    }

    static let shared = ImportWorkBudget()

    private let lock = NSLock()
    private let heavyWorkSemaphore = DispatchSemaphore(value: 1)
    private var isPlaybackActive = false
    private var exclusiveWorkInFlight = 0
    private var completedWorkCount = 0
    private var deferredWorkCount = 0
    private var totalDeferredSeconds: TimeInterval = 0
    private var lastDeferredWorkClass = "none"

    private init() {}

    func setPlaybackActive(_ isActive: Bool) {
        lock.lock()
        isPlaybackActive = isActive
        lock.unlock()
    }

    func performExclusiveHeavyWork<T>(_ work: () throws -> T) rethrows -> T {
        heavyWorkSemaphore.wait()
        defer {
            heavyWorkSemaphore.signal()
        }

        return try work()
    }

    func performScheduledHeavyWork<T>(
        _ workClass: WorkClass,
        work: () throws -> T
    ) throws -> T {
        try waitIfPlaybackActive(workClass)
        heavyWorkSemaphore.wait()
        markExclusiveWorkStarted()
        defer {
            markExclusiveWorkFinished()
            heavyWorkSemaphore.signal()
        }

        return try work()
    }

    func waitIfPlaybackActive(_ workClass: WorkClass = .rendererMaintenance) throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        let delay = playbackBackoff(for: workClass)
        guard delay > 0 else {
            return
        }

        recordDeferral(workClass: workClass, duration: delay)
        Thread.sleep(forTimeInterval: delay)
    }

    func waitForAsyncTurn(_ workClass: WorkClass) async throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        let delay = playbackBackoff(for: workClass)
        guard delay > 0 else {
            return
        }

        recordDeferral(workClass: workClass, duration: delay)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    func snapshot() -> ImportWorkBudgetSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        return ImportWorkBudgetSnapshot(
            isPlaybackActive: isPlaybackActive,
            exclusiveWorkInFlight: exclusiveWorkInFlight,
            completedWorkCount: completedWorkCount,
            deferredWorkCount: deferredWorkCount,
            totalDeferredSeconds: totalDeferredSeconds,
            lastDeferredWorkClass: lastDeferredWorkClass
        )
    }

    private func playbackBackoff(for workClass: WorkClass) -> TimeInterval {
        lock.lock()
        let shouldBackOff = isPlaybackActive
        lock.unlock()
        return shouldBackOff ? workClass.playbackBackoff : 0
    }

    private func markExclusiveWorkStarted() {
        lock.lock()
        exclusiveWorkInFlight += 1
        lock.unlock()
    }

    private func markExclusiveWorkFinished() {
        lock.lock()
        exclusiveWorkInFlight = max(exclusiveWorkInFlight - 1, 0)
        completedWorkCount += 1
        lock.unlock()
    }

    private func recordDeferral(workClass: WorkClass, duration: TimeInterval) {
        lock.lock()
        deferredWorkCount += 1
        totalDeferredSeconds += duration
        lastDeferredWorkClass = workClass.rawValue
        lock.unlock()
    }
}
