// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UnDupe",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Pure engine: scanning, models, duplicate detection, safe deletion.
        // No UI dependencies so it can be unit-tested in isolation.
        .target(
            name: "UnDupeCore"
        ),

        // The SwiftUI application.
        .executableTarget(
            name: "UnDupe",
            dependencies: ["UnDupeCore"]
        ),

        // Headless CLI used to validate and benchmark the engine
        // (e.g. compare totals against `du`).
        .executableTarget(
            name: "undupe-scan",
            dependencies: ["UnDupeCore"]
        ),

        .testTarget(
            name: "UnDupeCoreTests",
            dependencies: ["UnDupeCore"]
        ),

        .testTarget(
            name: "UnDupeTests",
            dependencies: ["UnDupe", "UnDupeCore"]
        ),
    ]
)
