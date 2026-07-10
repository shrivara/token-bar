// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "token-bar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "token-bar", path: "Sources/token-bar")
    ]
)
