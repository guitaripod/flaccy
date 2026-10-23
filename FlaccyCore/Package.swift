// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlaccyCore",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v13),
    ],
    products: [
        .library(name: "FlaccyCore", targets: ["FlaccyCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/guitaripod/MidgarKit", exact: "4.3.1")
    ],
    targets: [
        .target(
            name: "FlaccyCore",
            dependencies: [.product(name: "MidgarCore", package: "MidgarKit")]
        ),
        .testTarget(
            name: "FlaccyCoreTests",
            dependencies: ["FlaccyCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
