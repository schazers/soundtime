import Foundation

final class ImportWorkBudget: @unchecked Sendable {
    static let shared = ImportWorkBudget()

    private let lock = NSLock()
    private var isPlaybackActive = false

    private init() {}

    func setPlaybackActive(_ isActive: Bool) {
        lock.lock()
        isPlaybackActive = isActive
        lock.unlock()
    }

    func waitIfPlaybackActive() throws {
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }

            lock.lock()
            let shouldWait = isPlaybackActive
            lock.unlock()

            guard shouldWait else {
                return
            }

            Thread.sleep(forTimeInterval: 0.012)
        }
    }
}
