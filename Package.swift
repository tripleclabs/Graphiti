// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Graphiti",
    platforms: [.macOS(.v26), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "Graphiti", targets: ["Graphiti"]),
        .executable(name: "graphiti-benchmarks", targets: ["GraphitiBenchmarks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tripleclabs/GraphQL.git", revision: "cb0ac5ef76fa6ee3f36f5b49d6ca9c0e92f3d308"),
    ],
    targets: [
        .target(
            name: "Graphiti",
            dependencies: ["GraphQL"],
            swiftSettings: [.enableUpcomingFeature("SendableMetatypes")]
        ),
        .executableTarget(
            name: "GraphitiBenchmarks",
            dependencies: [
                "Graphiti",
                .product(name: "GraphQL", package: "GraphQL"),
            ],
            path: "Benchmarks/GraphitiBenchmarks",
            swiftSettings: [.enableUpcomingFeature("SendableMetatypes")]
        ),
        .testTarget(
            name: "GraphitiTests",
            dependencies: ["Graphiti"],
            resources: [.copy("FederationTests/GraphQL")],
            swiftSettings: [.enableUpcomingFeature("SendableMetatypes")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
