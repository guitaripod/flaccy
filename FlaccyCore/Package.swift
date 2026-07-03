// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlaccyCore",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v12),
    ],
    products: [
        .library(name: "FlaccyCore", targets: ["FlaccyCore"])
    ],
    targets: [
        .target(name: "FlaccyCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "FlaccyCoreTests",
            dependencies: ["FlaccyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
