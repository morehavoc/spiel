// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spiel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpielCore", targets: ["SpielCore"]),
        .executable(name: "spiel-cli", targets: ["SpielCLI"]),
        // The user-facing `spiel` command. Built as `spiel-tool` because SwiftPM puts
        // every executable in one folder and APFS is case-insensitive: a product named
        // `spiel` would be the same file as the app's `Spiel`. bundle.sh installs it
        // as Spiel.app/Contents/Helpers/spiel.
        .executable(name: "spiel-tool", targets: ["SpielTool"]),
        .executable(name: "Spiel", targets: ["SpielApp"]),
    ],
    dependencies: [
        // EXACT, not `from:`. `from: "0.15.6"` accepts any later 0.x, so a clean
        // rebuild months from now could silently pull different code into an app that
        // holds Accessibility and Microphone grants and sees every word dictated.
        // The pin plus the committed Package.resolved (which records the commit hash)
        // is what makes a rebuild reproducible. Bump both deliberately.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
    ],
    targets: [
        .target(
            name: "SpielCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(name: "SpielCLI", dependencies: ["SpielCore"]),
        .executableTarget(name: "SpielTool", dependencies: ["SpielCore"]),
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
