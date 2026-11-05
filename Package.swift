// swift-tools-version: 6.4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SynchronizedKit",
    products: [
        .library(
            name: "SynchronizedKit",
            targets: ["SynchronizedKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0")
    ],
    targets: [
        .macro(
            name: "SynchronizedKitMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "SynchronizedKit",
            dependencies: ["SynchronizedKitMacros"]
        ),
        .testTarget(
            name: "SynchronizedKitTests",
            dependencies: ["SynchronizedKit"]
        ),
        .testTarget(
            name: "SynchronizedKitMacrosTests",
            dependencies: [
                "SynchronizedKitMacros",
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
