// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LimeLight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LimeCore", targets: ["LimeCore"]),
        .executable(name: "limelightd", targets: ["limelightd"]),
        .executable(name: "limelight", targets: ["limelight"]),
        .executable(name: "borders", targets: ["borders"]),
    ],
    targets: [
        .systemLibrary(name: "CSkyLight"),
        .target(
            name: "LimeCore",
            dependencies: ["CSkyLight"],
            path: "Sources/LimeCore"
        ),
        .executableTarget(
            name: "limelightd",
            dependencies: ["LimeCore"],
            path: "Sources/limelightd"
        ),
        .executableTarget(
            name: "limelight",
            dependencies: ["LimeCore"],
            path: "Sources/limelight"
        ),
        .executableTarget(
            name: "borders",
            dependencies: ["LimeCore"],
            path: "Sources/borders"
        ),
        .testTarget(
            name: "LimeCoreTests",
            dependencies: ["LimeCore"],
            path: "Tests/LimeCoreTests"
        ),
    ]
)
