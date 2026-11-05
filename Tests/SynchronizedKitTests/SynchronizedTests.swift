import Foundation
import SynchronizedKit
import Testing

@Synchronized
final class Settings {
    static var shared: Settings = Settings(retries: 1)

    let id: Int = 1
    var name: String = "default"
    var retries: Int
    var onChange: (@Sendable (String) -> Void)?
    var history: [String] = []

    init(retries: Int) {
        self.retries = retries
    }

    var summary: String {
        "\(name) x\(retries)"
    }
}

func requireSendable<T: Sendable>(_: T.Type) {}

@Test func classBecomesSendable() {
    requireSendable(Settings.self)
}

@Test func defaultAndInitValues() {
    let settings = Settings(retries: 3)
    #expect(settings.name == "default")
    #expect(settings.retries == 3)
    #expect(settings.summary == "default x3")
}

@Test func readsAndWrites() {
    let settings = Settings(retries: 0)
    settings.name = "changed"
    settings.retries += 2
    #expect(settings.summary == "changed x2")
}

@Test func staticSharedCanBeReplaced() {
    let original = Settings.shared
    Settings.shared = Settings(retries: 9)
    #expect(Settings.shared.retries == 9)
    Settings.shared = original
}

@Test func sendableClosureProperty() {
    let settings = Settings(retries: 0)
    settings.onChange = { value in
        #expect(value == "ping")
    }
    settings.onChange?("ping")
}

@Test func lockedValueGuardsNonSendableState() async {
    final class Counter {
        var value = 0
    }
    let counter = LockedValue(Counter())
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<1_000 {
            group.addTask {
                counter.withLock { $0.value += 1 }
            }
        }
    }
    #expect(counter.withLock { $0.value } == 1_000)
}

@Test func concurrentWritesDontCrash() async {
    let settings = Settings(retries: 0)
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<1_000 {
            group.addTask {
                settings.name = "task \(i)"
                _ = settings.name
            }
        }
    }
    #expect(settings.name.hasPrefix("task "))
}

@Test func inPlaceMutationsAreAtomic() async {
    let settings = Settings(retries: 0)
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<1_000 {
            group.addTask {
                settings.retries += 1
                settings.history.append("\(i)")
            }
        }
    }
    #expect(settings.retries == 1_000)
    #expect(settings.history.count == 1_000)
}

@Test func propertiesShareOneLock() {
    let settings = Settings(retries: 0)
    let writerStarted = DispatchSemaphore(value: 0)
    let writerDone = DispatchSemaphore(value: 0)
    // A mutating method keeps `history`'s `_modify` (and so the lock) held
    // while its closure runs.
    settings.history.withUnsafeMutableBufferPointer { _ in
        // Same thread: re-entering the recursive lock doesn't deadlock.
        #expect(settings.name == "default")
        Thread.detachNewThread {
            writerStarted.signal()
            settings.name = "other thread"
            writerDone.signal()
        }
        writerStarted.wait()
        // Other thread: writing `name` waits for the lock `history` holds.
        #expect(writerDone.wait(timeout: .now() + 0.2) == .timedOut)
        #expect(settings.name == "default")
    }
    writerDone.wait()
    #expect(settings.name == "other thread")
}
