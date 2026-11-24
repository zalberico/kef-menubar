// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KEFMenuBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KEFKit", targets: ["KEFKit"]),
        .executable(name: "KEFMenuBar", targets: ["KEFMenuBar"]),
        .executable(name: "kefctl", targets: ["kefctl"]),
    ],
    targets: [
        // Protocol layer: transport, TLS, request signing, typed values, events, discovery.
        .target(name: "KEFKit"),
        // The menu bar app.
        .executableTarget(name: "KEFMenuBar", dependencies: ["KEFKit"]),
        // Small CLI used to exercise KEFKit against a real speaker.
        .executableTarget(name: "kefctl", dependencies: ["KEFKit"]),
        .testTarget(name: "KEFKitTests", dependencies: ["KEFKit"]),
    ]
)
