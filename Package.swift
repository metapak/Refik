// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "refik",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "refik", targets: ["refik"]), .executable(name: "refikHook", targets: ["refikHook"]), .executable(name: "refikCLI", targets: ["refikCLI"])],
    targets: [
        .target(name: "RefikInteractionWire", path: "Sources/RefikInteractionWire"),
        .executableTarget(name: "refik", dependencies: ["RefikInteractionWire"], path: "Sources/refik"),
        .executableTarget(name: "refikHook", dependencies: ["RefikInteractionWire"], path: "Sources/refikHook"),
        .executableTarget(name: "refikCLI", path: "Sources/refikCLI"),
        .testTarget(name: "refikTests", dependencies: ["refik", "RefikInteractionWire"], path: "Tests/refikTests")
    ]
)
