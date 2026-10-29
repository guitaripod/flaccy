// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "FlaccyServerEmbed",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FlaccyServerEmbed", targets: ["FlaccyServerEmbed"])
    ],
    targets: [
        .binaryTarget(
            name: "FlaccyServerEmbedFFI",
            path: "Artifacts/FlaccyServerEmbedFFI.xcframework"
        ),
        .target(name: "flaccy_server_embed_ffiFFI"),
        .target(
            name: "FlaccyServerEmbedBindings",
            dependencies: ["flaccy_server_embed_ffiFFI", "FlaccyServerEmbedFFI"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "FlaccyServerEmbed",
            dependencies: ["FlaccyServerEmbedBindings"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "FlaccyServerEmbedTests",
            dependencies: ["FlaccyServerEmbed"],
            resources: [.copy("Resources")],
            swiftSettings: strictSettings
        ),
    ]
)
