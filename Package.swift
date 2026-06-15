// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Roca",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "RocaCore", targets: ["RocaCore"]),
        .library(name: "RocaProviders", targets: ["RocaProviders"]),
        .library(name: "RocaServices", targets: ["RocaServices"]),
        .library(name: "RocaStorage", targets: ["RocaStorage"]),
        .library(name: "RocaTestingSupport", targets: ["RocaTestingSupport"]),
        .executable(name: "RocaEval", targets: ["RocaEval"])
    ],
    dependencies: [
        .package(url: "https://github.com/moonshine-ai/moonshine-swift.git", exact: "0.0.60"),
        .package(path: "Vendor/KokoroSwift"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2")
    ],
    targets: [
        .target(
            name: "RocaCore",
            path: "Packages/RocaCore/Sources/RocaCore"
        ),
        .target(
            name: "RocaProviders",
            dependencies: [
                "RocaCore",
                .product(name: "MoonshineVoice", package: "moonshine-swift"),
                .product(name: "KokoroSwift", package: "KokoroSwift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
            ],
            path: "Packages/RocaProviders/Sources/RocaProviders",
            resources: [
                .process("Resources/kokoro-mlx.json"),
                .process("Resources/ModelAssessments"),
                .process("Resources/moonshine-medium-streaming-en.json")
            ]
        ),
        .target(
            name: "RocaServices",
            dependencies: ["RocaCore"],
            path: "Packages/RocaServices/Sources/RocaServices"
        ),
        .target(
            name: "RocaStorage",
            dependencies: ["RocaCore"],
            path: "Packages/RocaStorage/Sources/RocaStorage"
        ),
        .target(
            name: "RocaEvalSupport",
            dependencies: ["RocaCore", "RocaProviders", "RocaServices", "RocaTestingSupport"],
            path: "Tools/RocaEvalSupport/Sources/RocaEvalSupport"
        ),
        .executableTarget(
            name: "RocaEval",
            dependencies: ["RocaEvalSupport"],
            path: "Tools/RocaEval/Sources/RocaEval"
        ),
        .target(
            name: "RocaTestingSupport",
            dependencies: ["RocaCore", "RocaServices"],
            path: "Packages/RocaTestingSupport/Sources/RocaTestingSupport"
        ),
        .testTarget(
            name: "RocaCoreTests",
            dependencies: ["RocaCore", "RocaTestingSupport"],
            path: "Packages/RocaCore/Tests/RocaCoreTests"
        ),
        .testTarget(
            name: "RocaProvidersTests",
            dependencies: ["RocaCore", "RocaProviders"],
            path: "Packages/RocaProviders/Tests/RocaProvidersTests"
        ),
        .testTarget(
            name: "RocaServicesTests",
            dependencies: ["RocaCore", "RocaServices", "RocaTestingSupport"],
            path: "Packages/RocaServices/Tests/RocaServicesTests"
        ),
        .testTarget(
            name: "RocaStorageTests",
            dependencies: ["RocaCore", "RocaStorage"],
            path: "Packages/RocaStorage/Tests/RocaStorageTests"
        ),
        .testTarget(
            name: "RocaEvalSupportTests",
            dependencies: ["RocaEvalSupport"],
            path: "Tools/RocaEvalSupport/Tests/RocaEvalSupportTests"
        )
    ]
)
