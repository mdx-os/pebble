// swift-tools-version: 6.2
import PackageDescription

// Layers, lowest first. A layer may import only the layers below it,
// and SwiftPM enforces that through the dependency lists here.
//   PebbleCore  plain types, no UI, no platform frameworks beyond Foundation
//   PebbleUI    SwiftUI views shared by Mac, iPhone and iPad
let package = Package(
    name: "PebbleKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PebbleCore", targets: ["PebbleCore"]),
        .library(name: "PebbleUI", targets: ["PebbleUI"]),
    ],
    targets: [
        .target(name: "PebbleCore"),
        .target(name: "PebbleUI", dependencies: ["PebbleCore"]),
        .testTarget(name: "PebbleCoreTests", dependencies: ["PebbleCore"]),
        .testTarget(name: "PebbleUITests", dependencies: ["PebbleUI", "PebbleCore"]),
    ]
)
