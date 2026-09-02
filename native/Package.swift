// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spiel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpielCore", targets: ["SpielCore"]),
        .executable(name: "spiel-cli", targets: ["SpielCLI"]),
        .executable(name: "Spiel", targets: ["SpielApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
    ],
    targets: [
        .target(
            name: "SpielCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(name: "SpielCLI", dependencies: ["SpielCore"]),
        .executableTarget(
            name: "SpielApp",
            dependencies: ["SpielCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
