import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Synchronized`: declares the shared locks, tags each `var` with
/// `@SynchronizedProperty` and adds `Sendable`.
public struct SynchronizedMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Non-classes are reported once, by the extension expansion.
        guard declaration.is(ClassDeclSyntax.self) else {
            return []
        }
        let variables = declaration.memberBlock.members
            .compactMap { $0.decl.as(VariableDeclSyntax.self) }
            .filter(\.isSynchronized)

        var members: [DeclSyntax] = []
        if variables.contains(where: { !$0.isStatic }) {
            members.append("private let _synchronizedLock = SynchronizedKit::SynchronizedLock()")
        }
        if variables.contains(where: \.isStatic) {
            members.append(
                "private static let _synchronizedStaticLock = SynchronizedKit::SynchronizedLock()")
        }
        return members
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let variable = member.as(VariableDeclSyntax.self),
            variable.isSynchronized,
            !variable.hasAttribute(named: "SynchronizedProperty")
        else {
            return []
        }
        return ["@SynchronizedProperty"]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: node, message: SynchronizedDiagnostic.notAClass)
            ])
        }
        guard classDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.final) }) else {
            // A macro can't rewrite the class it's attached to, so offer a
            // fix-it that inserts `final` right before the `class` keyword.
            var finalClass = classDecl
            finalClass.modifiers.append(
                DeclModifierSyntax(
                    name: .keyword(
                        .final,
                        leadingTrivia: classDecl.classKeyword.leadingTrivia,
                        trailingTrivia: .space
                    )
                )
            )
            finalClass.classKeyword.leadingTrivia = []
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: classDecl.classKeyword,
                    message: SynchronizedDiagnostic.notFinal,
                    fixIt: .replace(
                        message: SynchronizedFixIt.addFinal,
                        oldNode: classDecl,
                        newNode: finalClass
                    )
                )
            ])
        }
        // Already declared `Sendable` by hand: nothing to add.
        guard !protocols.isEmpty else {
            return []
        }
        return [try ExtensionDeclSyntax("extension \(type.trimmed): Sendable {}")]
    }
}

/// `@SynchronizedProperty`: turns a stored `var` into get/set/_modify
/// accessors over a private stored peer, guarded by the class's shared lock.
public struct SynchronizedPropertyMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let property = try SynchronizedPropertyInfo(declaration)
        let storage = property.storageName
        let lock = property.lockName

        var accessors: [AccessorDeclSyntax] = []
        if !property.isStatic {
            // Lets the property be assigned in `init` or keep its default value.
            accessors.append(
                """
                @storageRestrictions(initializes: \(storage))
                init(initialValue) {
                    \(storage) = initialValue
                }
                """
            )
        }
        accessors.append(
            """
            get {
                \(lock).lock()
                defer {
                    \(lock).unlock()
                }
                return SynchronizedKit::_synchronizedSendable(\(storage))
            }
            """
        )
        accessors.append(
            """
            set {
                \(lock).lock()
                defer {
                    \(lock).unlock()
                }
                \(storage) = newValue
            }
            """
        )
        accessors.append(
            """
            _modify {
                \(lock).lock()
                defer {
                    \(lock).unlock()
                }
                yield &\(storage)
            }
            """
        )
        return accessors
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let property = try SynchronizedPropertyInfo(declaration)
        let storage = property.storageName
        let type = property.type

        // `@safe nonisolated(unsafe)`: safe because every access holds the shared lock.
        if property.isStatic {
            guard let initialValue = property.initialValue else {
                throw DiagnosticsError(diagnostics: [
                    Diagnostic(
                        node: property.binding,
                        message: SynchronizedDiagnostic.staticNeedsInitialValue)
                ])
            }
            return [
                "@safe nonisolated(unsafe) private static var \(storage): \(type) = \(initialValue)"
            ]
        }
        return ["@safe nonisolated(unsafe) private var \(storage): \(type)"]
    }
}

/// The parts of a `var` declaration the property macro needs, validated once.
struct SynchronizedPropertyInfo {
    let binding: PatternBindingSyntax
    let name: TokenSyntax
    let type: TypeSyntax
    let initialValue: ExprSyntax?
    let isStatic: Bool

    var storageName: TokenSyntax {
        .identifier("_" + name.text)
    }

    /// Declared on the class by `@Synchronized`.
    var lockName: TokenSyntax {
        isStatic ? "_synchronizedStaticLock" : "_synchronizedLock"
    }

    init(_ declaration: some DeclSyntaxProtocol) throws {
        guard let variable = declaration.as(VariableDeclSyntax.self),
            variable.bindingSpecifier.tokenKind == .keyword(.var)
        else {
            throw Self.error(declaration, .notAVar)
        }
        guard variable.bindings.count == 1, let binding = variable.bindings.first else {
            throw Self.error(variable, .multipleBindings)
        }
        for modifier in variable.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.weak), .keyword(.unowned):
                throw Self.error(modifier, .weakOrUnowned)
            case .keyword(.lazy):
                throw Self.error(modifier, .lazy)
            default:
                break
            }
        }
        if binding.accessorBlock != nil {
            throw Self.error(binding, .hasAccessors)
        }
        guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
            throw Self.error(binding.pattern, .notAnIdentifier)
        }
        guard let type = binding.typeAnnotation?.type else {
            throw Self.error(binding, .missingType(identifier.identifier.text))
        }

        self.binding = binding
        self.name = identifier.identifier.trimmed
        self.type = type.trimmed
        self.initialValue = binding.initializer?.value.trimmed
        self.isStatic = variable.isStatic
    }

    private static func error(_ node: some SyntaxProtocol, _ message: SynchronizedDiagnostic)
        -> DiagnosticsError
    {
        DiagnosticsError(diagnostics: [Diagnostic(node: node, message: message)])
    }
}

enum SynchronizedDiagnostic: DiagnosticMessage {
    case notAClass
    case notFinal
    case notAVar
    case multipleBindings
    case weakOrUnowned
    case lazy
    case hasAccessors
    case notAnIdentifier
    case missingType(String)
    case staticNeedsInitialValue

    var message: String {
        switch self {
        case .notAClass:
            "@Synchronized can only be applied to a class"
        case .notFinal:
            "@Synchronized requires a 'final' class; only final classes can be Sendable"
        case .notAVar:
            "@SynchronizedProperty can only be applied to a 'var'"
        case .multipleBindings:
            "@Synchronized requires one property per 'var' declaration"
        case .weakOrUnowned:
            "@Synchronized does not support 'weak' or 'unowned' properties"
        case .lazy:
            "@Synchronized does not support 'lazy' properties"
        case .hasAccessors:
            "@Synchronized does not support properties with 'willSet' or 'didSet'"
        case .notAnIdentifier:
            "@Synchronized does not support tuple patterns"
        case .missingType(let name):
            "@Synchronized requires an explicit type annotation on '\(name)'"
        case .staticNeedsInitialValue:
            "static properties under @Synchronized need an initial value"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SynchronizedKit", id: "\(self)")
    }

    var severity: DiagnosticSeverity { .error }
}

enum SynchronizedFixIt: FixItMessage {
    case addFinal

    var message: String {
        switch self {
        case .addFinal:
            "Add 'final'"
        }
    }

    var fixItID: MessageID {
        MessageID(domain: "SynchronizedKit", id: "\(self)")
    }
}

extension VariableDeclSyntax {
    /// A stored `var` that `@Synchronized` guards.
    var isSynchronized: Bool {
        bindingSpecifier.tokenKind == .keyword(.var) && !isComputed
    }

    var isStatic: Bool {
        modifiers.contains {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }
    }

    func hasAttribute(named name: String) -> Bool {
        attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name
        }
    }

    /// True for `var x: Int { ... }` with a getter, i.e. not stored.
    /// Observed properties (`willSet`/`didSet`) count as stored, so the
    /// property macro can report them.
    var isComputed: Bool {
        guard let accessorBlock = bindings.first?.accessorBlock else {
            return false
        }
        switch accessorBlock.accessors {
        case .getter:
            return true
        case .accessors(let accessors):
            return accessors.contains {
                switch $0.accessorSpecifier.tokenKind {
                case .keyword(.willSet), .keyword(.didSet):
                    false
                default:
                    true
                }
            }
        }
    }
}

@main
struct SynchronizedKitPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SynchronizedMacro.self,
        SynchronizedPropertyMacro.self,
    ]
}
