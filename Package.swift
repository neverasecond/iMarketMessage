// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iMarketMessage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // v0.2 names are first; the legacy products remain aliases so an
        // existing local build script does not silently break during rename.
        .library(name: "iMarketMessageCore", targets: ["MarketMessageCore"]),
        .library(name: "MarketMessageCore", targets: ["MarketMessageCore"]),
        .executable(name: "iMM", targets: ["MarketMessageApp"]),
        .executable(name: "MarketMessage", targets: ["MarketMessageApp"]),
        .executable(name: "market-message-cli", targets: ["MarketMessageCLI"]),
        .executable(name: "iMM-gateway", targets: ["MarketMessageGateway"]),
        .executable(name: "market-message-gateway", targets: ["MarketMessageGateway"])
    ],
    targets: [
        .target(
            name: "MarketMessageCore",
            path: "Sources/MarketMessageCore"
        ),
        .executableTarget(
            name: "MarketMessageApp",
            dependencies: ["MarketMessageCore"],
            path: "Sources/MarketMessageApp"
        ),
        .executableTarget(
            name: "MarketMessageCLI",
            dependencies: ["MarketMessageCore"],
            path: "Sources/MarketMessageCLI"
        ),
        .executableTarget(
            name: "MarketMessageGateway",
            dependencies: ["MarketMessageCore"],
            path: "Sources/MarketMessageGateway"
        ),
        .testTarget(
            name: "MarketMessageCoreTests",
            dependencies: ["MarketMessageCore"],
            path: "Tests/MarketMessageCoreTests"
        )
    ]
)
