// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MisakiSwift",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(
      name: "MisakiSwift",
      targets: ["MisakiSwift"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6")
  ],
  targets: [
    .target(
      name: "MisakiSwift",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
     ],
     resources: [.copy("Resources")]
    ),
  ]
)
