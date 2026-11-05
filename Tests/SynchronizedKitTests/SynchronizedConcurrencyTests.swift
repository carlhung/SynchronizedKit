import Foundation
import SynchronizedKit
import Testing

/// Calls `entry` while the ledger is being mutated, so code inside `entry`
/// runs with the owning object's lock held through `_modify`.
struct Ledger: Sendable {
    private(set) var entries: [Int] = []

    mutating func record(_ entry: () -> Int) {
        entries.append(entry())
    }
}

@Synchronized
final class Account {
    var name: String = ""
    var balance: Int = 0
    var history: [Int] = []
    var tags: [String: Int] = [:]
    var ledger: Ledger = Ledger()
    var audit: Ledger = Ledger()

    /// Touches two more properties; each access locks again on the same thread
    /// when called from inside `ledger.record`.
    func deposit(_ amount: Int) {
        balance += amount
        history.append(balance)
    }
}

@Synchronized
final class Registry {
    static var created: Int = 0
    static var names: [String] = []
}

/// Runs `body` `iterations` times on a pool of threads; each thread runs many
/// iterations. Returns `false` if it didn't finish in time, so a deadlock fails
/// the test instead of hanging the run.
private func runConcurrently(
    _ iterations: Int,
    timeout: TimeInterval = 30,
    _ body: @escaping @Sendable (Int) -> Void
) -> Bool {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        DispatchQueue.concurrentPerform(iterations: iterations, execute: body)
        done.signal()
    }
    return done.wait(timeout: .now() + timeout) == .success
}

private func currentThreadID() -> ObjectIdentifier {
    ObjectIdentifier(Thread.current)
}

// MARK: - 1. Concurrent access doesn't crash

/// Unprotected, these copy-on-write types corrupt memory and crash
/// when written from many threads at once.
@Test func concurrentReadsAndWritesOfManyTypes() {
    let account = Account()
    let iterations = 20_000

    let finished = runConcurrently(iterations) { i in
        switch i % 4 {
        case 0:
            account.name = "writer \(i)"
        case 1:
            account.history.append(i)
        case 2:
            account.tags["key \(i % 16)", default: 0] += 1
        default:
            // Readers racing the writers above.
            _ = account.name.count
            _ = account.history.last
            _ = account.tags.count
        }
    }

    #expect(finished)
    #expect(account.name.hasPrefix("writer "))
    #expect(account.history.count == iterations / 4)
    #expect(account.tags.values.reduce(0, +) == iterations / 4)
}

/// `+=` goes through `_modify`, so no increment is lost.
@Test func concurrentIncrementsAreNotLost() {
    let account = Account()
    let iterations = 50_000

    let finished = runConcurrently(iterations) { _ in
        account.balance += 1
    }

    #expect(finished)
    #expect(account.balance == iterations)
}

@Test func concurrentStaticAccess() {
    let iterations = 10_000

    let finished = runConcurrently(iterations) { i in
        Registry.created += 1
        Registry.names.append("\(i)")
    }

    #expect(finished)
    #expect(Registry.created == iterations)
    #expect(Registry.names.count == iterations)
}

@Test func concurrentAccessFromTasks() async {
    let account = Account()

    await withTaskGroup(of: Void.self) { group in
        for i in 0..<5_000 {
            group.addTask {
                account.balance += 1
                account.history.append(i)
                _ = account.history.count
            }
        }
    }

    #expect(account.balance == 5_000)
    #expect(Set(account.history) == Set(0..<5_000))
}

// MARK: - 2. Re-entering the lock on the same thread

/// Each iteration holds the lock through `ledger`'s `_modify`, then locks
/// again on the same thread for `balance` and `history`. A non-recursive lock
/// would deadlock on the first iteration. Because everything inside `record`
/// runs under one lock, other threads can't interleave, so all three
/// properties agree.
@Test func reentrantAccessWhileOtherThreadsCompete() {
    let account = Account()
    let threads = LockedValue(Set<ObjectIdentifier>())
    let iterations = 10_000

    let finished = runConcurrently(iterations) { _ in
        threads.withLock { _ = $0.insert(currentThreadID()) }
        account.ledger.record {
            account.deposit(1)
            return account.balance
        }
    }

    #expect(finished, "deadlocked: the lock isn't re-entrant")
    let expected = Array(1...iterations)
    #expect(account.balance == iterations)
    #expect(account.history == expected)
    #expect(account.ledger.entries == expected)

    // Many iterations shared each thread, and (on a multi-core machine)
    // several threads really did compete for the lock.
    let threadCount = threads.withLock { $0.count }
    #expect(threadCount < iterations)
    if ProcessInfo.processInfo.activeProcessorCount > 1 {
        #expect(threadCount > 1)
    }
}

/// Re-enters the lock three levels deep on one thread (`audit`, then
/// `ledger`, then `balance`/`history`), from several threads at once.
///
/// Each level must be a *different* property: modifying the same property
/// again while it's already being modified (e.g. `ledger.record` inside
/// `ledger.record`) breaks Swift's exclusivity rule and traps, even though
/// the recursive lock itself would allow it.
@Test func nestedReentrantAccessAcrossProperties() {
    let account = Account()
    let iterations = 10_000

    let finished = runConcurrently(iterations) { _ in
        account.audit.record {
            account.ledger.record {
                account.deposit(1)
                return account.balance
            }
            return account.ledger.entries.count
        }
    }

    #expect(finished, "deadlocked: the lock isn't re-entrant")
    let expected = Array(1...iterations)
    #expect(account.history == expected)
    #expect(account.ledger.entries == expected)
    #expect(account.audit.entries == expected)
}

/// While one thread holds the lock (and re-enters it), another thread's
/// access to the same object must wait.
@Test func otherThreadsWaitWhileLockIsReentered() {
    let account = Account()
    let writerStarted = DispatchSemaphore(value: 0)
    let writerDone = DispatchSemaphore(value: 0)

    account.ledger.record {
        account.deposit(1)  // re-enter on this thread
        Thread.detachNewThread {
            writerStarted.signal()
            account.balance = 100
            writerDone.signal()
        }
        writerStarted.wait()
        #expect(writerDone.wait(timeout: .now() + 0.2) == .timedOut)
        #expect(account.balance == 1)  // re-enter again; still our value
        return account.balance
    }

    #expect(writerDone.wait(timeout: .now() + 5) == .success)
    #expect(account.balance == 100)
    #expect(account.ledger.entries == [1])
}
