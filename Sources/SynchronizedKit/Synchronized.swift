import Foundation

/// Makes a `final class` `Sendable` by guarding every stored `var` with a
/// lock. All instance properties share one `NSRecursiveLock` per instance;
/// all `static` properties share one `NSRecursiveLock` per class.
///
/// ```swift
/// @Synchronized
/// final class Settings {
///     static var shared: Settings = Settings()
///     var name: String = "default"
///     var retries: Int
///
///     init(retries: Int) { self.retries = retries }
/// }
/// ```
///
/// Requirements and limits:
/// - Every `var` needs an explicit type annotation, and that type must be
///   `Sendable`: getters hand the value out of the lock.
/// - Each access holds the lock on its own. In-place mutations such as
///   `x += 1` or `items.append(y)` go through `_modify` and are atomic, but
///   updating two properties together is *not*.
/// - `let` properties are left alone and must already be `Sendable`.
/// - `weak`, `lazy`, `unowned` and observed (`willSet`/`didSet`) properties
///   are rejected.
@attached(member, names: named(_synchronizedLock), named(_synchronizedStaticLock))
@attached(memberAttribute)
@attached(extension, conformances: Sendable)
public macro Synchronized() = #externalMacro(module: "SynchronizedKitMacros", type: "SynchronizedMacro")

/// Turns one stored `var` into get/set/_modify accessors guarded by the
/// class's shared lock. Added automatically by `@Synchronized`, which also
/// declares that lock; don't write it yourself.
@attached(accessor, names: named(init), named(get), named(set), named(_modify))
@attached(peer, names: prefixed(_))
public macro SynchronizedProperty() = #externalMacro(module: "SynchronizedKitMacros", type: "SynchronizedPropertyMacro")

/// The lock type `@Synchronized` declares. Spelled through this module so
/// expanded code compiles even where the file doesn't import Foundation.
public typealias SynchronizedLock = NSRecursiveLock

/// Used by expanded getters: fails to compile when a property's type isn't
/// `Sendable`, and inlines away to nothing otherwise.
@inlinable @inline(__always)
public func _synchronizedSendable<Value: Sendable>(_ value: Value) -> Value {
    value
}
