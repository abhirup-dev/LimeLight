// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FocusFX",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FocusFXCore", targets: ["FocusFXCore"]),
        .executable(name: "FocusFXDaemon", targets: ["FocusFXDaemon"]),
        .executable(name: "focusfx", targets: ["focusfx"]),
        .executable(name: "borders", targets: ["borders"]),
    ],
    targets: [
        .systemLibrary(name: "CSkyLight"),
        .target(
            name: "FocusFXCore",
            dependencies: ["CSkyLight"],
            path: "Sources/FocusFXCore"
        ),
        .executableTarget(
            name: "FocusFXDaemon",
            dependencies: ["FocusFXCore"],
            path: "Sources/FocusFXDaemon"
        ),
        .executableTarget(
            name: "focusfx",
            dependencies: ["FocusFXCore"],
            path: "Sources/focusfx"
        ),
        .executableTarget(
            name: "borders",
            dependencies: ["FocusFXCore"],
            path: "Sources/borders"
        ),
        .testTarget(
            name: "FocusFXCoreTests",
            dependencies: ["FocusFXCore"],
            path: "Tests/FocusFXCoreTests"
        ),
    ]
)
