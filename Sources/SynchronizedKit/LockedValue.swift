import Foundation

@dynamicMemberLookup
public final class LockedValue<Value: ~Copyable>: Sendable {
    private let lock = NSRecursiveLock()
    nonisolated(unsafe)
        private var value: Value

    public init(_ initialValue: consuming sending Value) {
        value = initialValue
    }

    public func withLock<Result: ~Copyable, E>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public subscript<Subject>(dynamicMember keyPath: KeyPath<Value, Subject>) -> Subject {
        yielding borrow {
            lock.lock()
            defer { lock.unlock() }
            yield value[keyPath: keyPath]
        }
    }

    // public subscript<Subject>(dynamicMember keyPath: KeyPath<Value, Subject>) -> sending Subject {
    //     yielding borrow {
    //         lock.lock()
    //         defer { lock.unlock() }
    //         yield value[keyPath: keyPath]
    //     }
    // }

    // public subscript<Subject>(
    //     dynamicMember keyPath: WritableKeyPath<Value, Subject>
    // ) -> sending Subject {
    //     yielding borrow {
    //         lock.lock()
    //         defer { lock.unlock() }
    //         yield value[keyPath: keyPath]
    //     }
    //     yielding mutate {
    //         lock.lock()
    //         defer { lock.unlock() }
    //         yield &value[keyPath: keyPath]
    //     }
    //     set {
    //         lock.lock()
    //         defer { lock.unlock() }
    //         value[keyPath: keyPath] = newValue
    //     }
    // }
}
