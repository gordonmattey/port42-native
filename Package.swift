// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Port42",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0")
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
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Port42Lib",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "Port42Tests",
            dependencies: ["Port42Lib"],
            path: "Tests/Port42Tests"
        )
    ]
)
