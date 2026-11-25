// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KEFMenuBar",
    // iOS is only the floor for the libraries (the iPhone app has its own project).
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "KEFKit", targets: ["KEFKit"]),
        .library(name: "KEFAppCore", targets: ["KEFAppCore"]),
        .executable(name: "KEFMenuBar", targets: ["KEFMenuBar"]),
        .executable(name: "kefctl", targets: ["kefctl"]),
    ],
    targets: [
        // Protocol layer: transport, TLS, request signing, typed values, events, discovery.
        .target(name: "KEFKit"),
        // What the Mac and iPhone apps share: the live speaker model, preferences, volume
        // policy and the one-shot commands used by widgets, controls and intents.
        .target(name: "KEFAppCore", dependencies: ["KEFKit"]),
        // The menu bar app.
        .executableTarget(name: "KEFMenuBar", dependencies: ["KEFKit", "KEFAppCore"]),
        // Small CLI used to exercise KEFKit against a real speaker.
        .executableTarget(name: "kefctl", dependencies: ["KEFKit"]),
        .testTarget(name: "KEFKitTests", dependencies: ["KEFKit"]),
    ]
)
