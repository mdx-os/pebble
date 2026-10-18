// swift-tools-version: 6.2
import PackageDescription

// Layers, lowest first. A layer may import only the layers below it,
// and SwiftPM enforces that through the dependency lists here.
//   PebbleCore   plain types. No SwiftUI, no networking.
//   PebblePulse  competitor watch: fetching and snapshots. Imports PebbleCore.
//   PebbleModel  model adapter. ModelClient, the on-device placeholder and
//                CloudModel (off by default). Imports PebbleCore. A later
//                MLX or Ollama adapter lives here.
//   PebbleBackground  gives the background runner time: BGTaskScheduler on
//                iPhone and iPad, NSBackgroundActivityScheduler on the Mac.
//                Imports PebbleCore. Scheduling decisions are pure
//                functions in `BackgroundPlan`; the runner, its store and
//                its switch live in PebbleCore's `Background.swift`.
//   PebbleUI     SwiftUI views shared by Mac, iPhone and iPad.
//                Imports PebbleCore and PebbleModel.
// SourceScan is not a layer. It lives under Tests, is in no product, and
// only the test targets use it, to read Swift source for their guards.
// TestScratch is the same kind of helper: a folder of scratch files for
// each test, removed when it ends.
// GuardScan is one too: the source guards' shared scanner and their rules,
// built on SwiftSyntax. swift-syntax is pinned to an exact version and only
// GuardScan uses it, so no product, and nothing the app ships, depends on it.
let package = Package(
    name: "PebbleKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PebbleCore", targets: ["PebbleCore"]),
        .library(name: "PebblePulse", targets: ["PebblePulse"]),
        .library(name: "PebbleModel", targets: ["PebbleModel"]),
        .library(name: "PebbleBackground", targets: ["PebbleBackground"]),
        .library(name: "PebbleUI", targets: ["PebbleUI"]),
        .executable(name: "pulse", targets: ["pulse"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
    ],
    targets: [
        .target(name: "PebbleCore"),
        .target(name: "PebblePulse", dependencies: ["PebbleCore"]),
        .target(name: "PebbleModel", dependencies: ["PebbleCore"]),
        .target(name: "PebbleBackground", dependencies: ["PebbleCore"]),
        .target(name: "PebbleUI", dependencies: ["PebbleCore", "PebbleModel"]),
        .executableTarget(name: "pulse", dependencies: ["PebbleCore", "PebblePulse"]),
        .target(name: "SourceScan", path: "Tests/SourceScan"),
        .target(name: "TestScratch", path: "Tests/TestScratch"),
        .target(name: "GuardScan",
                dependencies: [
                    .product(name: "SwiftSyntax", package: "swift-syntax"),
                    .product(name: "SwiftParser", package: "swift-syntax"),
                    .product(name: "SwiftOperators", package: "swift-syntax"),
                ],
                path: "Tests/GuardScan"),
        .testTarget(name: "PebbleCoreTests", dependencies: ["PebbleCore", "SourceScan", "TestScratch", "GuardScan"]),
        .testTarget(name: "PebblePulseTests", dependencies: ["PebblePulse", "PebbleCore"]),
        .testTarget(name: "PebbleModelTests", dependencies: ["PebbleModel", "PebbleCore"]),
        .testTarget(name: "PebbleBackgroundTests",
                    dependencies: ["PebbleBackground", "PebbleCore", "SourceScan", "TestScratch"]),
        .testTarget(name: "PebbleUITests",
                    dependencies: ["PebbleUI", "PebbleModel", "PebbleCore", "PebbleBackground", "SourceScan",
                                   "TestScratch", "GuardScan"]),
    ]
)
