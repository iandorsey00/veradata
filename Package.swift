// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VeraData",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VeraDataCore", targets: ["VeraDataCore"]),
        .executable(name: "VeraData", targets: ["VeraDataApp"]),
        .executable(name: "veradata-cli", targets: ["VeraDataCLI"]),
    ],
    targets: [
        .target(name: "VeraDataCore", resources: [.process("Resources")]),
        .executableTarget(
            name: "VeraDataApp",
            dependencies: ["VeraDataCore"],
            resources: [.copy("Resources/demo.json")]
        ),
        .executableTarget(name: "VeraDataCLI", dependencies: ["VeraDataCore"]),
        .testTarget(name: "VeraDataCoreTests", dependencies: ["VeraDataCore"]),
    ]
)
