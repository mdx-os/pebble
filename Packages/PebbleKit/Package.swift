// swift-tools-version: 6.2
import PackageDescription

// Layers, lowest first. A layer may import only the layers below it,
// and SwiftPM enforces that through the dependency lists here.
//   PebbleCore   plain types. No SwiftUI, no networking.
//   PebblePulse  competitor watch: fetching and snapshots. Imports PebbleCore.
//   PebbleModel  model adapter. ModelClient, the on-device placeholder,
//                and the MLX adapter. Imports PebbleCore. MLX loads a model
//                directory already on the device. It does not download weights.
//                An Ollama adapter can live here later.
//   PebbleUI     SwiftUI views shared by Mac, iPhone and iPad.
//                Imports PebbleCore and PebbleModel.
let package = Package(
    name: "PebbleKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PebbleCore", targets: ["PebbleCore"]),
        .library(name: "PebblePulse", targets: ["PebblePulse"]),
        .library(name: "PebbleModel", targets: ["PebbleModel"]),
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
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(name: "PebbleUI", dependencies: ["PebbleCore", "PebbleModel"]),
        .executableTarget(name: "pulse", dependencies: ["PebbleCore", "PebblePulse"]),
        .testTarget(name: "PebbleCoreTests", dependencies: ["PebbleCore"]),
        .testTarget(name: "PebblePulseTests", dependencies: ["PebblePulse", "PebbleCore"]),
        .testTarget(name: "PebbleModelTests", dependencies: ["PebbleModel", "PebbleCore"]),
        .testTarget(name: "PebbleUITests", dependencies: ["PebbleUI", "PebbleModel", "PebbleCore"]),
    ]
)
