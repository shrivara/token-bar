// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "token-bar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TokenBarCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "token-bar",
            dependencies: ["TokenBarCore"],
            path: "Sources/token-bar",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "TokenBarCoreTests", dependencies: ["TokenBarCore"]),
    ]
)
