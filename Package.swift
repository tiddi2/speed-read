// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "sr",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Dependency budget: ≤ 2 (PRD §10.6). This is 1 of 2.
        // Pinned to 1.15.0: newer tags use #Preview macros, which cannot be
        // compiled with a Command-Line-Tools-only toolchain (no PreviewsMacros
        // plugin). Bump once full Xcode is installed (Phase 3).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0"),
    ],
    targets: [
        .target(
            name: "SRCore",
            path: "Sources/SRCore"
        ),
        .executableTarget(
            name: "sr",
            dependencies: [
                "SRCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/sr"
        ),
        .testTarget(
            name: "SRCoreTests",
            dependencies: ["SRCore"],
            path: "Tests/SRCoreTests",
            resources: [.copy("fixtures"), .copy("fixtures-no")]
        ),
        .testTarget(
            name: "SRAppTests",
            dependencies: ["sr"],
            path: "Tests/SRAppTests"
        ),
    ]
)
