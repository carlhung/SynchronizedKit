import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import SynchronizedKitMacros

private let macros: [String: MacroSpec] = [
    "Synchronized": MacroSpec(type: SynchronizedMacro.self, conformances: ["Sendable"]),
    "SynchronizedProperty": MacroSpec(type: SynchronizedPropertyMacro.self),
]

final class SynchronizedMacroTests: XCTestCase {
    func testExpansion() {
        assertMacroExpansion(
            """
            @Synchronized
            final class Settings {
                static var shared: Settings = Settings()
                let id: Int = 1
                var name: String = "default"
                var computed: Int { 0 }
            }
            """,
            expandedSource: """
                final class Settings {
                    static var shared: Settings {
                        get {
                            _synchronizedStaticLock.lock()
                            defer {
                                _synchronizedStaticLock.unlock()
                            }
                            return SynchronizedKit::_synchronizedSendable(_shared)
                        }
                        set {
                            _synchronizedStaticLock.lock()
                            defer {
                                _synchronizedStaticLock.unlock()
                            }
                            _shared = newValue
                        }
                        _modify {
                            _synchronizedStaticLock.lock()
                            defer {
                                _synchronizedStaticLock.unlock()
                            }
                            yield &_shared
                        }
                    }

                    @safe nonisolated(unsafe) private static var _shared: Settings = Settings()
                    let id: Int = 1
                    var name: String {
                        @storageRestrictions(initializes: _name)
                        init(initialValue) {
                            _name = initialValue
                        }
                        get {
                            _synchronizedLock.lock()
                            defer {
                                _synchronizedLock.unlock()
                            }
                            return SynchronizedKit::_synchronizedSendable(_name)
                        }
                        set {
                            _synchronizedLock.lock()
                            defer {
                                _synchronizedLock.unlock()
                            }
                            _name = newValue
                        }
                        _modify {
                            _synchronizedLock.lock()
                            defer {
                                _synchronizedLock.unlock()
                            }
                            yield &_name
                        }
                    }

                    @safe nonisolated(unsafe) private var _name: String
                    var computed: Int { 0 }

                    private let _synchronizedLock = SynchronizedKit::SynchronizedLock()

                    private static let _synchronizedStaticLock = SynchronizedKit::SynchronizedLock()
                }

                extension Settings: Sendable {
                }
                """,
            macroSpecs: macros
        )
    }

    func testRequiresFinalClass() {
        assertMacroExpansion(
            """
            @Synchronized
            class Settings {
            }
            """,
            expandedSource: """
                class Settings {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Synchronized requires a 'final' class; only final classes can be Sendable",
                    line: 2,
                    column: 1
                )
            ],
            macroSpecs: macros
        )
    }

    func testRequiresTypeAnnotation() {
        assertMacroExpansion(
            """
            @SynchronizedProperty
            var name = "default"
            """,
            expandedSource: """
                var name = "default"
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Synchronized requires an explicit type annotation on 'name'",
                    line: 2,
                    column: 5
                ),
                DiagnosticSpec(
                    message: "@Synchronized requires an explicit type annotation on 'name'",
                    line: 2,
                    column: 5
                ),
            ],
            macroSpecs: macros
        )
    }

    func testRejectsObservers() {
        assertMacroExpansion(
            """
            @SynchronizedProperty
            var name: String = "" {
                didSet {}
            }
            """,
            expandedSource: """
                var name: String = "" {
                    didSet {}
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Synchronized does not support properties with 'willSet' or 'didSet'",
                    line: 2,
                    column: 5
                ),
                DiagnosticSpec(
                    message: "@Synchronized does not support properties with 'willSet' or 'didSet'",
                    line: 2,
                    column: 5
                ),
            ],
            macroSpecs: macros
        )
    }

    func testRejectsWeak() {
        assertMacroExpansion(
            """
            @SynchronizedProperty
            weak var delegate: AnyObject?
            """,
            expandedSource: """
                weak var delegate: AnyObject?
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Synchronized does not support 'weak' or 'unowned' properties",
                    line: 2,
                    column: 1
                ),
                DiagnosticSpec(
                    message: "@Synchronized does not support 'weak' or 'unowned' properties",
                    line: 2,
                    column: 1
                ),
            ],
            macroSpecs: macros
        )
    }
}
