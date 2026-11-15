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
        .package(url: "https://github.com/tripleclabs/GraphQL.git", revision: "e593b0696a3c0ca439bed088829b7c02a269625a"),
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
