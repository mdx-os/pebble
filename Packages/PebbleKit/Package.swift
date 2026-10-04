// swift-tools-version: 6.2
import PackageDescription

// Layers, lowest first. A layer may import only the layers below it,
// and SwiftPM enforces that through the dependency lists here.
//   PebbleCore   plain types. No UI, no networking.
//   PebblePulse  fetch pulse sources, save snapshots, diff them. Depends on PebbleCore.
//   PebbleUI     SwiftUI views shared by Mac, iPhone and iPad. Depends on PebbleCore.
// pebble-pulse is the command that runs the morning check. It is not a layer.
let package = Package(
    name: "PebbleKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PebbleCore", targets: ["PebbleCore"]),
        .library(name: "PebblePulse", targets: ["PebblePulse"]),
        .library(name: "PebbleUI", targets: ["PebbleUI"]),
        .executable(name: "pebble-pulse", targets: ["pebble-pulse"]),
    ],
    targets: [
        .target(name: "PebbleCore"),
        .target(name: "PebblePulse", dependencies: ["PebbleCore"]),
        .target(name: "PebbleUI", dependencies: ["PebbleCore"]),
        .executableTarget(name: "pebble-pulse", dependencies: ["PebblePulse"]),
        .testTarget(name: "PebbleCoreTests", dependencies: ["PebbleCore"]),
        .testTarget(
            name: "PebblePulseTests",
            dependencies: ["PebblePulse"],
            exclude: ["Fixtures"]
        ),
        .testTarget(name: "PebbleUITests", dependencies: ["PebbleUI", "PebbleCore"]),
    ]
)
