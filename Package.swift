// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalHandler",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "THCore"),
        .executableTarget(name: "th-hook", dependencies: ["THCore"]),
        .executableTarget(
            name: "TerminalHandler",
            dependencies: ["THCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "THCoreTests", dependencies: ["THCore"]),
    ]
)
