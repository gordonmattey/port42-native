// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "p42shell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "p42shell", path: "Sources/p42shell")
    ]
)
