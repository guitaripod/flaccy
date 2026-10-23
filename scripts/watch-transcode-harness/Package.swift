// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "watch-transcode-harness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../FlaccyCore"),
        .package(path: "../../../../packages/MidgarKit"),
    ],
    targets: [
        .executableTarget(
            name: "harness",
            dependencies: [
                .product(name: "FlaccyCore", package: "FlaccyCore"),
                .product(name: "MidgarCore", package: "MidgarKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        )
    ]
)
