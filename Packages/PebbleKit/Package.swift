// swift-tools-version: 6.2
import PackageDescription

// Layers, lowest first. A layer may import only the layers below it,
// and SwiftPM enforces that through the dependency lists here.
//   PebbleCore   plain types. No SwiftUI, no networking.
//   PebblePulse  competitor watch: fetching and snapshots. Imports PebbleCore.
//   PebbleUI     SwiftUI views shared by Mac, iPhone and iPad. Imports PebbleCore.
let package = Package(
    name: "PebbleKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PebbleCore", targets: ["PebbleCore"]),
        .library(name: "PebblePulse", targets: ["PebblePulse"]),
        .library(name: "PebbleUI", targets: ["PebbleUI"]),
        .executable(name: "pulse", targets: ["pulse"]),
    ],
    targets: [
        .target(name: "PebbleCore"),
        .target(name: "PebblePulse", dependencies: ["PebbleCore"]),
        .target(name: "PebbleUI", dependencies: ["PebbleCore"]),
        .executableTarget(name: "pulse", dependencies: ["PebbleCore", "PebblePulse"]),
        .testTarget(name: "PebbleCoreTests", dependencies: ["PebbleCore"]),
        .testTarget(name: "PebblePulseTests", dependencies: ["PebblePulse", "PebbleCore"]),
        .testTarget(name: "PebbleUITests", dependencies: ["PebbleUI", "PebbleCore"]),
    ]
)
