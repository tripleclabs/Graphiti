// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "Graphiti",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "Graphiti", targets: ["Graphiti"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tripleclabs/GraphQL.git", revision: "6e46beb2c5db08c75f488ff450831399de31cbe0"),
    ],
    targets: [
        .target(name: "Graphiti", dependencies: ["GraphQL"]),
        .testTarget(name: "GraphitiTests", dependencies: ["Graphiti"], resources: [
            .copy("FederationTests/GraphQL"),
        ]),
    ],
    swiftLanguageVersions: [.v5, .version("6")]
)
