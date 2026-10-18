// swift-tools-version: 6.2
import PackageDescription

// Layers, lowest first. A layer may import only the layers below it,
// and SwiftPM enforces that through the dependency lists here.
//   PebbleCore   plain types. No SwiftUI, no networking.
//   PebblePulse  competitor watch: fetching and snapshots. Imports PebbleCore.
//   PebbleModel  model adapter. ModelClient, the on-device placeholder,
//                CloudModel (off by default) and the MLX adapter. Imports
//                PebbleCore. MLX loads a model directory already on the
//                device. It does not download weights.
//                An Ollama adapter can live here later.
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
        // Pinned. The default mlx-swift-lm trait builds an Apple framework
        // bridge this adapter does not call, so no traits are enabled.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.32.3",
            traits: []
        ),
        // Direct so the adapter can cap the memory cache. Package.resolved
        // pins the exact revision.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            .upToNextMinor(from: "0.32.3")
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.4"
        ),
    ],
    targets: [
        .target(name: "PebbleCore"),
        .target(name: "PebblePulse", dependencies: ["PebbleCore"]),
        .target(
            name: "PebbleModel",
            dependencies: [
                "PebbleCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(name: "PebbleBackground", dependencies: ["PebbleCore"]),
        .target(name: "PebbleUI", dependencies: ["PebbleCore", "PebbleModel"]),
        .executableTarget(name: "pulse", dependencies: ["PebbleCore", "PebblePulse"]),
        .target(name: "SourceScan", path: "Tests/SourceScan"),
        .target(name: "TestScratch", path: "Tests/TestScratch"),
        .testTarget(name: "PebbleCoreTests", dependencies: ["PebbleCore", "SourceScan", "TestScratch"]),
        .testTarget(name: "PebblePulseTests", dependencies: ["PebblePulse", "PebbleCore"]),
        .testTarget(name: "PebbleModelTests", dependencies: ["PebbleModel", "PebbleCore"]),
        .testTarget(name: "PebbleBackgroundTests",
                    dependencies: ["PebbleBackground", "PebbleCore", "SourceScan", "TestScratch"]),
        .testTarget(name: "PebbleUITests",
                    dependencies: ["PebbleUI", "PebbleModel", "PebbleCore", "PebbleBackground", "SourceScan",
                                   "TestScratch"]),
    ]
)
