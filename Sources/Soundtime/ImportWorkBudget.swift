import Foundation
import Dispatch

final class ImportWorkBudget: @unchecked Sendable {
    static let shared = ImportWorkBudget()

    private let lock = NSLock()
    private let heavyWorkSemaphore = DispatchSemaphore(value: 1)
    private var isPlaybackActive = false

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

    func waitIfPlaybackActive() throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        lock.lock()
        let shouldBackOff = isPlaybackActive
        lock.unlock()

        if shouldBackOff {
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}
