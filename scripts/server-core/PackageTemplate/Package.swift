// swift-tools-version: 6.2
import PackageDescription

let xcframeworkPath = "__XCFRAMEWORK_PATH__"

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "FlaccyServerCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "FlaccyServerCore", targets: ["FlaccyServerCore"]),
    ],
    targets: [
        .binaryTarget(name: "FlaccyServerCoreFFI", path: xcframeworkPath),
        .target(
            name: "FlaccyServerCoreBindings",
            dependencies: ["FlaccyServerCoreFFI"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "FlaccyServerCore",
            dependencies: ["FlaccyServerCoreBindings"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "FlaccyServerCoreTests",
            dependencies: ["FlaccyServerCore"],
            swiftSettings: strictSettings
        ),
    ]
)
