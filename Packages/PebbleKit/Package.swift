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
// SourceScan is not a layer. It lives under Tests and only tests use it,
// to read Swift source for their guards.
// ReconTestSupport is the same kind of thing: the test engines, gates and
// waits that the core and UI tests share, kept in one copy.
// TestScratch is the same kind of helper: a folder of scratch files for
// each test, removed when it ends.
// PromiseWords is one too: the phrases that promise the device, and the
// lines allowed to say them with a written reason.
// SourceScan and PromiseWords are products only so Tools/GuardKit, the
// source guards' own package, can read them. The app never links them.
// Its only outside dependencies are MLX and swift-transformers, for the
// model adapter. swift-syntax lives only in Tools/GuardKit, and `make
// graph-check` fails if it ever comes in here. mlx-swift-lm declares it for
// a macro this package never links, so SwiftPM leaves it out of the graph,
// but any edit here, a comment too, makes the next resolve pin it again:
// take that pin out of Package.resolved and Config/Package.resolved.
let package = Package(
    name: "PebbleKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PebbleCore", targets: ["PebbleCore"]),
        .library(name: "PebblePulse", targets: ["PebblePulse"]),
        .library(name: "PebbleModel", targets: ["PebbleModel"]),
        .library(name: "PebbleBackground", targets: ["PebbleBackground"]),
        .library(name: "PebbleUI", targets: ["PebbleUI"]),
        .library(name: "SourceScan", targets: ["SourceScan"]),
        .library(name: "PromiseWords", targets: ["PromiseWords"]),
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
        .target(name: "ReconTestSupport", dependencies: ["PebbleCore"], path: "Tests/ReconTestSupport"),
        .target(name: "TestScratch", path: "Tests/TestScratch"),
        .target(name: "PromiseWords", dependencies: ["PebbleCore"], path: "Tests/PromiseWords"),
        .testTarget(name: "PebbleCoreTests",
                    dependencies: ["PebbleCore", "SourceScan", "ReconTestSupport", "TestScratch", "PromiseWords"]),
        .testTarget(name: "PebblePulseTests", dependencies: ["PebblePulse", "PebbleCore"]),
        .testTarget(name: "PebbleModelTests", dependencies: ["PebbleModel", "PebbleCore"]),
        .testTarget(name: "PebbleBackgroundTests",
                    dependencies: ["PebbleBackground", "PebbleCore", "SourceScan", "TestScratch"]),
        .testTarget(name: "PebbleUITests",
                    dependencies: ["PebbleUI", "PebbleModel", "PebbleCore", "PebbleBackground", "SourceScan",
                                   "ReconTestSupport", "TestScratch"]),
    ]
)
