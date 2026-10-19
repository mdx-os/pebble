// swift-tools-version: 6.2
import PackageDescription

// MLXLLM and MLXLMCommon from mlx-swift-lm 3.32.3, revision
// 3b339ad6e3b3f44c8121ecff5131c7fd55e075e6. The upstream package also
// builds a macro target, and that macro is why it depends on
// swift-syntax. These two libraries do not use the macro, so this copy
// leaves it out. swift-syntax stays in Tools/GuardKit.
let package = Package(
    name: "MLXLM",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MLXLLM", targets: ["MLXLLM"]),
        .library(name: "MLXLMCommon", targets: ["MLXLMCommon"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            .upToNextMinor(from: "0.32.3")
        ),
    ],
    targets: [
        .target(
            name: "MLXLMCommon",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
            ]
        ),
        .target(
            name: "MLXLLM",
            dependencies: [
                "MLXLMCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
            ]
        ),
    ]
)
