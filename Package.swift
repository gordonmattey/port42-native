// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Port42",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Port42",
            dependencies: ["Port42Lib"],
            path: "Sources/Port42",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "Port42Lib",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/Port42Lib",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "Port42B",
            dependencies: ["Port42Lib"],
            path: "Sources/Port42B"
        ),
        .testTarget(
            name: "Port42Tests",
            dependencies: ["Port42Lib"],
            path: "Tests/Port42Tests"
        )
    ]
)
