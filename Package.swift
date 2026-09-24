// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mlx-bar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mlxbar",
            path: "Sources/mlxbar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
