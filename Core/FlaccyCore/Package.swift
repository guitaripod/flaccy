// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
let engineProducts: [Product] = []
let engineDependencies: [Package.Dependency] = []
let engineTargets: [Target] = []
#else
let engineProducts: [Product] = [
    .library(name: "FlaccyEngine", targets: ["FlaccyEngine"])
]
let engineDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
]
let engineTargets: [Target] = [
    .target(
        name: "FlaccyEngine",
        dependencies: [
            "FlaccyCore",
            .product(name: "MidgarCore", package: "MidgarKit"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]
    ),
    .testTarget(
        name: "FlaccyEngineTests",
        dependencies: [
            "FlaccyEngine",
            "FlaccyCore",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]
    ),
]
#endif

let package = Package(
    name: "FlaccyCore",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FlaccyCore", targets: ["FlaccyCore"])
    ] + engineProducts,
    dependencies: [
        .package(path: "../../../../packages/MidgarKit")
    ] + engineDependencies,
    targets: [
        .target(
            name: "FlaccyCore",
            dependencies: [.product(name: "MidgarCore", package: "MidgarKit")]
        ),
        .testTarget(
            name: "FlaccyCoreTests",
            dependencies: ["FlaccyCore"],
            exclude: ["Fixtures"]
        ),
    ] + engineTargets,
    swiftLanguageModes: [.v6]
)
