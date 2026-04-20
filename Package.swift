// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "blip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Blip", targets: ["Blip"]),
        .executable(name: "BlipApp", targets: ["BlipApp"]),
        .executable(name: "BlipHooks", targets: ["BlipHooks"]),
        .executable(name: "BlipSetup", targets: ["BlipSetup"]),
        .library(name: "BlipCore", targets: ["BlipCore"]),
    ],
    targets: [
        .target(
            name: "BlipCore",
            path: "Sources/BlipCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BlipApp",
            dependencies: ["BlipCore"],
            path: "Sources/BlipApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BlipHooks",
            dependencies: ["BlipCore"],
            path: "Sources/BlipHooks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BlipSetup",
            dependencies: ["BlipCore"],
            path: "Sources/BlipSetup",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Blip",
            dependencies: ["BlipCore"],
            path: "Sources/Blip",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BlipCoreTests",
            dependencies: ["BlipCore"],
            path: "Tests/BlipCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
