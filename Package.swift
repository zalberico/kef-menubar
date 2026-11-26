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
    dependencies: [
        // Auto-updates for the Mac app only. Pinned exactly; bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Protocol layer: transport, TLS, request signing, typed values, events, discovery.
        .target(name: "KEFKit"),
        // What the Mac and iPhone apps share: the live speaker model, preferences, volume
        // policy and the one-shot commands used by widgets, controls and intents.
        .target(name: "KEFAppCore", dependencies: ["KEFKit"]),
        // The menu bar app. scripts/build-app.sh embeds Sparkle.framework in the .app.
        .executableTarget(
            name: "KEFMenuBar",
            dependencies: [
                "KEFKit", "KEFAppCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ]
        ),
        // Small CLI used to exercise KEFKit against a real speaker.
        .executableTarget(name: "kefctl", dependencies: ["KEFKit"]),
        .testTarget(name: "KEFKitTests", dependencies: ["KEFKit"]),
        .testTarget(name: "KEFAppCoreTests", dependencies: ["KEFAppCore", "KEFKit"]),
    ]
)
