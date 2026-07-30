import Foundation

/// Owns cancelable keyed work and prevents an older completion from removing a
/// replacement task registered under the same key.
@MainActor
final class KeyedTaskRegistry<Key: Hashable & Sendable> {
    private struct Entry {
        let generation: UUID
        let cancel: () -> Void
    }

    private var entries: [Key: Entry] = [:]

    var count: Int {
        entries.count
    }

    func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    @discardableResult
    func startDetached(
        for key: Key,
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> UUID? {
        guard entries[key] == nil else {
            return nil
        }

        let generation = UUID()
        let task = Task.detached(priority: priority) { [weak self] in
            await operation()
            await self?.finish(key: key, generation: generation)
        }
        entries[key] = Entry(
            generation: generation,
            cancel: {
                task.cancel()
            }
        )
        return generation
    }

    /// Replaces any prior task for the key and gives the new task its
    /// generation before the task body is constructed.
    @discardableResult
    func replaceTask(
        for key: Key,
        makeTask: (UUID) -> Task<Void, Never>
    ) -> UUID {
        cancel(key)
        let generation = UUID()
        entries[key] = Entry(generation: generation, cancel: {})
        let task = makeTask(generation)
        if entries[key]?.generation == generation {
            entries[key] = Entry(
                generation: generation,
                cancel: {
                    task.cancel()
                }
            )
        } else {
            task.cancel()
        }
        return generation
    }

    /// Registers externally scheduled work, such as a DispatchQueue job, under
    /// the same latest-generation contract as Task-based work.
    @discardableResult
    func replaceExternal(
        for key: Key,
        cancel: @escaping () -> Void
    ) -> UUID {
        self.cancel(key)
        let generation = UUID()
        entries[key] = Entry(generation: generation, cancel: cancel)
        return generation
    }

    func isCurrent(_ key: Key, generation: UUID) -> Bool {
        entries[key]?.generation == generation
    }

    func cancel(_ key: Key) {
        entries.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        let cancellations = entries.values.map(\.cancel)
        entries.removeAll(keepingCapacity: false)
        cancellations.forEach { $0() }
    }

    func finish(key: Key, generation: UUID) {
        guard entries[key]?.generation == generation else {
            return
        }
        entries[key] = nil
    }
}
