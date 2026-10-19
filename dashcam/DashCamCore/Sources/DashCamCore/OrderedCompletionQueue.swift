import Foundation

/// Delivers asynchronous results in submission order and supports barriers after prior work.
/// All methods and callbacks must run on the same serial queue. No queue is blocked while waiting.
public final class OrderedCompletionQueue<Value> {
    private enum Entry {
        case result(UUID, (Value) -> Void)
        case barrier(() -> Void)
    }

    private var entries: [Entry] = []
    private var pending: Set<UUID> = []
    private var results: [UUID: Value] = [:]
    private var isDraining = false

    public init() {}

    /// Reserves a place before starting an asynchronous operation.
    public func enqueue(_ completion: @escaping (Value) -> Void) -> UUID {
        let ticket = UUID()
        pending.insert(ticket)
        entries.append(.result(ticket, completion))
        return ticket
    }

    public func complete(_ ticket: UUID, with value: Value) {
        guard pending.remove(ticket) != nil else { return }
        results[ticket] = value
        drain()
    }

    /// Runs after all work submitted so far is delivered, without waiting for later work.
    public func barrier(_ completion: @escaping () -> Void) {
        entries.append(.barrier(completion))
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while let entry = entries.first {
            switch entry {
            case .result(let ticket, let completion):
                guard let value = results.removeValue(forKey: ticket) else { return }
                entries.removeFirst()
                completion(value)
            case .barrier(let completion):
                entries.removeFirst()
                completion()
            }
        }
    }
}
