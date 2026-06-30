// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wkspike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "wkspike", path: "Sources/wkspike")
    ]
)
