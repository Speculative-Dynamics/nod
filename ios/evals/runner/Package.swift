// swift-tools-version: 6.0
// MLX build of the eval runner. run.sh builds this (with xcodebuild, so
// MLX's Metal shaders are compiled) when you pass --engine mlx:<path>.
// Sources/NodEval holds symlinks to the runner files and to the app's
// shared code, so the evals run exactly what ships.
import PackageDescription

let package = Package(
    name: "NodEval",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "nod-eval",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/NodEval",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
