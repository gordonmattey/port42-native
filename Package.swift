// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Port42",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Port42",
            dependencies: ["Port42Lib", "Sparkle"],
            path: "Sources/Port42",
            resources: [
                .process("Resources")
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
        .target(
            name: "Port42Lib",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "PostHog", package: "posthog-ios"),
                "GhosttyKit"
            ],
            path: "Sources/Port42Lib",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // GhosttyKit is a static archive; the consuming app must link the
                // system frameworks it references. Carbon provides the Text Input
                // Source APIs (TISCopyCurrentKeyboardLayoutInputSource etc.).
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "Port42Tests",
            dependencies: ["Port42Lib"],
            path: "Tests/Port42Tests"
        )
    ]
)
